/**
 * LSP Server
 *
 * Native Language Server Protocol implementation for the D-to-WASM compiler.
 * Speaks JSON-RPC 2.0 over stdin/stdout with Content-Length framing.
 *
 * Reuses the compile server's WarmState infrastructure for incremental
 * compilation, and the position index / declaration index for navigation.
 */
module server.lsp_server;

import std.stdio;
import std.json;
import std.string;
import std.conv;
import std.path;
import std.file;
import std.array;
import std.typecons : Nullable;

import ast.nodes;
import ast.statements;
import server.lsp_types;
import server.warm_state;
import server.position_index;

class LSPServer {
    private {
        WarmState warmState;
        PositionIndex[string] positionIndexes;  // absPath → index
        string[string] openDocuments;            // uri → source text
        bool running;
        bool initialized;

        // Compiler settings
        string backend;
        bool stackTrace;
        string[] importPaths;
    }

    this(string backend, bool stackTrace, string[] importPaths) {
        this.backend = backend;
        this.stackTrace = stackTrace;
        this.importPaths = importPaths;
        this.warmState = new WarmState();
        this.running = true;
    }

    /// Main event loop — reads from stdin, writes to stdout
    int run() {
        lspLog("LSP server started");

        while (running) {
            auto msg = readMessage();
            if (msg.isNull)
                break;

            auto response = handleMessage(msg);
            if (!response.isNull)
                sendMessage(response);
        }

        lspLog("LSP server stopped");
        return 0;
    }

    // ── JSON-RPC Framing ──

    private JSONValue readMessage() {
        // Read headers until empty line
        int contentLength = -1;

        while (true) {
            string line;
            try {
                line = stdin.readln().strip();
            } catch (Exception) {
                return JSONValue(null);
            }
            if (line is null)
                return JSONValue(null);
            if (line.length == 0)
                break;

            if (line.startsWith("Content-Length: "))
                contentLength = to!int(line["Content-Length: ".length .. $]);
        }

        if (contentLength <= 0)
            return JSONValue(null);

        // Read exactly contentLength bytes
        auto buf = new char[contentLength];
        auto got = stdin.rawRead(buf);
        if (got.length != contentLength)
            return JSONValue(null);

        try {
            return parseJSON(cast(string)got);
        } catch (Exception e) {
            lspLog("Failed to parse JSON: ", e.msg);
            return JSONValue(null);
        }
    }

    private void sendMessage(JSONValue msg) {
        string body_ = msg.toString();
        string header = "Content-Length: " ~ to!string(body_.length) ~ "\r\n\r\n";
        stdout.write(header);
        stdout.write(body_);
        stdout.flush();
    }

    private void sendNotification(string method, JSONValue params) {
        JSONValue msg;
        msg["jsonrpc"] = "2.0";
        msg["method"] = method;
        msg["params"] = params;
        sendMessage(msg);
    }

    // ── Message Dispatch ──

    private JSONValue handleMessage(JSONValue msg) {
        // Ignore responses (messages with id but no method) — e.g., from client
        if ("method" !in msg)
            return JSONValue(null);

        string method = msg["method"].str;
        bool isRequest = "id" in msg ? true : false;

        lspLog("← ", method);

        try {
            return dispatchMethod(method, isRequest, msg);
        } catch (Exception e) {
            lspLog("Error handling ", method, ": ", e.msg);
            if (isRequest)
                return jsonRPCError(msg, -32603, "Internal error: " ~ e.msg);
            return JSONValue(null);
        }
    }

    private JSONValue dispatchMethod(string method, bool isRequest, JSONValue msg) {
        switch (method) {
            case "initialize":
                return handleInitialize(msg);
            case "initialized":
                initialized = true;
                return JSONValue(null);
            case "shutdown":
                running = false;
                return jsonRPCResult(msg, JSONValue(null));
            case "exit":
                running = false;
                return JSONValue(null);
            case "textDocument/didOpen":
                handleDidOpen(msg);
                return JSONValue(null);
            case "textDocument/didChange":
                handleDidChange(msg);
                return JSONValue(null);
            case "textDocument/didSave":
                handleDidSave(msg);
                return JSONValue(null);
            case "textDocument/didClose":
                handleDidClose(msg);
                return JSONValue(null);
            case "textDocument/definition":
                return handleDefinition(msg);
            case "textDocument/hover":
                return handleHover(msg);
            case "textDocument/signatureHelp":
                return handleSignatureHelp(msg);
            case "textDocument/documentSymbol":
                return handleDocumentSymbol(msg);
            case "textDocument/references":
                return handleReferences(msg);
            case "textDocument/completion":
                return handleCompletion(msg);
            case "textDocument/codeLens":
                return handleCodeLens(msg);
            case "textDocument/semanticTokens/full":
                return handleSemanticTokensFull(msg);
            case "textDocument/prepareCallHierarchy":
                return handlePrepareCallHierarchy(msg);
            case "callHierarchy/incomingCalls":
                return handleCallHierarchyIncoming(msg);
            case "callHierarchy/outgoingCalls":
                return handleCallHierarchyOutgoing(msg);
            case "textDocument/prepareTypeHierarchy":
                return handlePrepareTypeHierarchy(msg);
            case "typeHierarchy/supertypes":
                return handleTypeHierarchySupertypes(msg);
            case "typeHierarchy/subtypes":
                return handleTypeHierarchySubtypes(msg);
            case "textDocument/prepareRename":
                return handlePrepareRename(msg);
            case "textDocument/rename":
                return handleRename(msg);
            case "textDocument/codeAction":
                return handleCodeAction(msg);
            case "workspace/didChangeWatchedFiles":
                handleDidChangeWatchedFiles(msg);
                return JSONValue(null);
            case "workspace/didChangeWorkspaceFolders":
                handleDidChangeWorkspaceFolders(msg);
                return JSONValue(null);
            default:
                if (isRequest)
                    return jsonRPCError(msg, -32601, "Method not found: " ~ method);
                return JSONValue(null);
        }
    }

    // ── LSP Handlers ──

    private JSONValue handleInitialize(JSONValue msg) {
        // Extract workspace root from client params for import path resolution
        auto initParams = msg["params"];
        if ("rootUri" in initParams && initParams["rootUri"].type != JSONType.null_) {
            string rootUri = initParams["rootUri"].str;
            string rootPath = uriToPath(rootUri);
            if (rootPath.length > 0 && exists(rootPath)) {
                // Add workspace root as an import search path
                bool alreadyHave = false;
                foreach (ip; importPaths) {
                    if (ip == rootPath) { alreadyHave = true; break; }
                }
                if (!alreadyHave)
                    importPaths ~= rootPath;
                // Also check for common source subdirectories
                foreach (subdir; ["src", "source"]) {
                    string sub = buildPath(rootPath, subdir);
                    if (exists(sub) && isDir(sub)) {
                        bool have = false;
                        foreach (ip; importPaths) {
                            if (ip == sub) { have = true; break; }
                        }
                        if (!have) importPaths ~= sub;
                    }
                }
                lspLog("Workspace root: ", rootPath);
            }
        }
        if ("workspaceFolders" in initParams
            && initParams["workspaceFolders"].type == JSONType.array)
        {
            foreach (folder; initParams["workspaceFolders"].array) {
                if ("uri" in folder) {
                    string folderPath = uriToPath(folder["uri"].str);
                    if (folderPath.length > 0 && exists(folderPath)) {
                        bool alreadyHave = false;
                        foreach (ip; importPaths) {
                            if (ip == folderPath) { alreadyHave = true; break; }
                        }
                        if (!alreadyHave)
                            importPaths ~= folderPath;
                    }
                }
            }
        }

        JSONValue caps;

        // Text document sync: incremental (mode 2)
        JSONValue syncOptions;
        syncOptions["openClose"] = true;
        syncOptions["change"] = 2;  // Incremental
        JSONValue saveOptions;
        saveOptions["includeText"] = true;
        syncOptions["save"] = saveOptions;
        caps["textDocumentSync"] = syncOptions;

        // Features we support
        caps["definitionProvider"] = true;
        caps["hoverProvider"] = true;
        caps["documentSymbolProvider"] = true;
        caps["referencesProvider"] = true;

        JSONValue sigHelp;
        sigHelp["triggerCharacters"] = JSONValue(["(", ","]);
        caps["signatureHelpProvider"] = sigHelp;

        JSONValue completion;
        completion["triggerCharacters"] = JSONValue([".", ":"]);
        caps["completionProvider"] = completion;

        // Code lens: reference counts on declarations
        JSONValue codeLens;
        codeLens["resolveProvider"] = false;
        caps["codeLensProvider"] = codeLens;

        // Semantic tokens: full document
        JSONValue semTokens;
        JSONValue semLegend;
        semLegend["tokenTypes"] = JSONValue(
            cast(JSONValue[])null);
        foreach (name; semanticTokenTypeNames)
            semLegend["tokenTypes"].array ~= JSONValue(name);
        semLegend["tokenModifiers"] = JSONValue(
            cast(JSONValue[])null);
        foreach (name; semanticTokenModifierNames)
            semLegend["tokenModifiers"].array ~= JSONValue(name);
        semTokens["legend"] = semLegend;
        semTokens["full"] = true;
        caps["semanticTokensProvider"] = semTokens;

        // Call hierarchy
        caps["callHierarchyProvider"] = true;

        // Type hierarchy
        caps["typeHierarchyProvider"] = true;

        // Rename with prepare support
        JSONValue rename;
        rename["prepareProvider"] = true;
        caps["renameProvider"] = rename;

        // Code actions (quickfixes)
        JSONValue codeAction;
        codeAction["codeActionKinds"] = JSONValue([JSONValue("quickfix")]);
        caps["codeActionProvider"] = codeAction;

        // Workspace capabilities
        JSONValue workspace;
        JSONValue workspaceFoldersCap;
        workspaceFoldersCap["supported"] = true;
        workspaceFoldersCap["changeNotifications"] = true;
        workspace["workspaceFolders"] = workspaceFoldersCap;
        caps["workspace"] = workspace;

        JSONValue result;
        result["capabilities"] = caps;

        JSONValue serverInfo;
        serverInfo["name"] = "d2wasm-lsp";
        serverInfo["version"] = "0.1.0";
        result["serverInfo"] = serverInfo;

        return jsonRPCResult(msg, result);
    }

    private void handleDidOpen(JSONValue msg) {
        auto params = msg["params"];
        auto td = params["textDocument"];
        string uri = td["uri"].str;
        string text = td["text"].str;

        openDocuments[uri] = text;
        compileAndPublishDiagnostics(uri, text);
    }

    private void handleDidChange(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;

        auto changes = params["contentChanges"].array;
        if (changes.length == 0) return;

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        foreach (change; changes) {
            if ("range" in change) {
                // Incremental sync: apply the edit
                auto range = Range.fromJSON(change["range"]);
                string newText = change["text"].str;

                string currentText = (uri in openDocuments) ? openDocuments[uri] : "";
                uint startOff = positionToByteOffset(range.start, currentText);
                uint endOff = positionToByteOffset(range.end, currentText);

                // Splice the text
                openDocuments[uri] = currentText[0 .. startOff] ~ newText
                    ~ currentText[endOff .. $];

                // Build TSInputEdit and notify warm state for incremental reparse
                import parser.tree_sitter_c : TSInputEdit, TSPoint;
                TSInputEdit edit;
                edit.start_byte = startOff;
                edit.old_end_byte = endOff;
                edit.new_end_byte = startOff + cast(uint)newText.length;
                edit.start_point = TSPoint(range.start.line, range.start.character);
                edit.old_end_point = TSPoint(range.end.line, range.end.character);
                // Compute new end point from new text
                uint newEndLine = range.start.line;
                uint newEndCol = range.start.character;
                foreach (c; newText) {
                    if (c == '\n') { newEndLine++; newEndCol = 0; }
                    else newEndCol++;
                }
                edit.new_end_point = TSPoint(newEndLine, newEndCol);

                warmState.applyFileChange(absPath, openDocuments[uri], &edit);
            } else {
                // Full sync fallback: take the entire text
                openDocuments[uri] = change["text"].str;
            }
        }

        // Don't recompile on every keystroke — wait for save
    }

    private void handleDidSave(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;

        string text;
        if (uri in openDocuments)
            text = openDocuments[uri];
        else {
            string path = uriToPath(uri);
            if (exists(path))
                text = readText(path);
        }

        if (text.length > 0)
            compileAndPublishDiagnostics(uri, text);
    }

    private void handleDidClose(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        openDocuments.remove(uri);
    }

    private JSONValue handleDefinition(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        auto pos = Position.fromJSON(params["position"]);

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        // Find expression at cursor
        auto pi = absPath in positionIndexes;
        if (pi is null)
            return jsonRPCResult(msg, JSONValue(null));

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        uint byteOffset = positionToByteOffset(pos, sourceText);

        auto expr = pi.findExprAt(byteOffset);
        if (expr is null)
            return jsonRPCResult(msg, JSONValue(null));

        // Check if it's an identifier with a resolved declaration
        import ast.expressions : IdentifierExpression;

        Declaration target;
        if (auto ident = cast(IdentifierExpression)expr)
            target = ident.declaration;

        if (target is null || target.location.filename.length == 0)
            return jsonRPCResult(msg, JSONValue(null));

        // Build location
        string targetSource = "";
        string targetPath = target.location.filename;
        if (exists(targetPath))
            targetSource = readText(targetPath);

        auto loc = Location(
            pathToURI(targetPath),
            sourceLocationToRange(
                target.location.startOffset,
                target.location.endOffset,
                targetSource)
        );

        return jsonRPCResult(msg, loc.toJSON());
    }

    private JSONValue handleHover(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        auto pos = Position.fromJSON(params["position"]);

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        auto pi = absPath in positionIndexes;
        if (pi is null)
            return jsonRPCResult(msg, JSONValue(null));

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        uint byteOffset = positionToByteOffset(pos, sourceText);

        auto expr = pi.findExprAt(byteOffset);
        if (expr is null)
            return jsonRPCResult(msg, JSONValue(null));

        import ast.nodes : Expression;
        auto typedExpr = cast(Expression)expr;
        if (typedExpr is null || typedExpr.type is null)
            return jsonRPCResult(msg, JSONValue(null));

        string hoverText = typedExpr.type.toString();

        // For identifiers, add the declaration name
        import ast.expressions : IdentifierExpression;
        if (auto ident = cast(IdentifierExpression)typedExpr) {
            if (ident.declaration !is null)
                hoverText = ident.name ~ ": " ~ hoverText;
        }

        JSONValue contents;
        contents["kind"] = "plaintext";
        contents["value"] = hoverText;

        JSONValue result;
        result["contents"] = contents;
        return jsonRPCResult(msg, result);
    }

    private JSONValue handleSignatureHelp(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        auto pos = Position.fromJSON(params["position"]);

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        auto ppi = absPath in positionIndexes;
        if (ppi is null)
            return jsonRPCResult(msg, JSONValue(null));

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        uint byteOffset = positionToByteOffset(pos, sourceText);

        // Scan backward from cursor to find the opening '(' and count commas
        // at the correct nesting level. This is more robust than AST lookup
        // because the source may be incomplete mid-typing.
        int activeParam = 0;
        uint openParenOffset = uint.max;
        int depth = 0;
        bool inString = false;
        bool inChar = false;

        if (byteOffset > 0 && byteOffset <= sourceText.length) {
            for (size_t i = byteOffset; i > 0; i--) {
                char c = sourceText[i - 1];

                // Simple string/char literal skip (scan backward)
                if (c == '"' && !inChar) {
                    inString = !inString;
                    continue;
                }
                if (c == '\'' && !inString) {
                    inChar = !inChar;
                    continue;
                }
                if (inString || inChar)
                    continue;

                if (c == ')' || c == ']') {
                    depth++;
                } else if (c == '(' || c == '[') {
                    if (depth > 0) {
                        depth--;
                    } else if (c == '(') {
                        openParenOffset = cast(uint)(i - 1);
                        break;
                    }
                } else if (c == ',' && depth == 0) {
                    activeParam++;
                }
            }
        }

        if (openParenOffset == uint.max)
            return jsonRPCResult(msg, JSONValue(null));

        // Find the function identifier just before the '('
        import ast.expressions : CallExpression, IdentifierExpression, MemberExpression;

        FunctionDecl funcDecl;

        // Try to find an expression at or just before the opening paren
        if (openParenOffset > 0) {
            auto expr = ppi.findExprAt(openParenOffset - 1);

            if (auto ident = cast(IdentifierExpression)expr) {
                funcDecl = cast(FunctionDecl)ident.declaration;
            } else if (auto member = cast(MemberExpression)expr) {
                // Method call: resolve member name on the object's type
                if (member.object !is null) {
                    auto typedObj = cast(Expression)member.object;
                    if (typedObj !is null && typedObj.type !is null) {
                        if (auto userType = cast(UserType)typedObj.type) {
                            if (userType.declaration !is null) {
                                if (auto child = member.memberName in userType.declaration.childIndex) {
                                    funcDecl = cast(FunctionDecl)*child;
                                }
                            }
                        }
                    }
                }
            }
        }

        // Fallback: try finding a CallExpression containing the cursor
        if (funcDecl is null) {
            auto node = ppi.findExprAt(byteOffset);
            if (auto call = cast(CallExpression)node) {
                if (auto ident = cast(IdentifierExpression)call.function_)
                    funcDecl = cast(FunctionDecl)ident.declaration;
            }
        }

        if (funcDecl is null)
            return jsonRPCResult(msg, JSONValue(null));

        // Build signature
        string sig = funcDecl.returnType !is null ? funcDecl.returnType.toString() : "void";
        sig ~= " " ~ funcDecl.name ~ "(";

        JSONValue[] paramInfos;
        foreach (i, param; funcDecl.parameters) {
            if (i > 0) sig ~= ", ";
            string paramStr = param.type !is null ? param.type.toString() : "?";
            paramStr ~= " " ~ param.name;
            sig ~= paramStr;

            JSONValue pi2;
            pi2["label"] = paramStr;
            paramInfos ~= pi2;
        }
        sig ~= ")";

        // Clamp activeParameter to valid range
        if (paramInfos.length > 0 && activeParam >= paramInfos.length)
            activeParam = cast(int)(paramInfos.length - 1);

        JSONValue sigInfo;
        sigInfo["label"] = sig;
        sigInfo["parameters"] = JSONValue(paramInfos);

        JSONValue result;
        result["signatures"] = JSONValue([sigInfo]);
        result["activeSignature"] = 0;
        result["activeParameter"] = activeParam;
        return jsonRPCResult(msg, result);
    }

    private JSONValue handleDocumentSymbol(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        // Find the module for this file
        import semantic.module_ : Module;
        import ast.nodes : FunctionDecl, StructDecl, ClassDecl, VariableDecl,
            ManifestConstantDecl, EnumDecl, TemplateDecl, AggregateDecl;

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        if (sourceText.length == 0 && exists(path))
            sourceText = readText(path);

        auto mod = findModule(absPath);
        if (mod is null || mod.topIndex is null)
            return jsonRPCResult(msg, emptyJSONArray());

        // Build document symbols from topIndex
        JSONValue[] symbols;
        foreach (name, decl; mod.topIndex) {
            auto sym = declToDocumentSymbol(decl, sourceText);
            if (!sym.isNull)
                symbols ~= sym;
        }

        return jsonRPCResult(msg, JSONValue(symbols));
    }

    private JSONValue handleReferences(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        auto pos = Position.fromJSON(params["position"]);

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        auto pi = absPath in positionIndexes;
        if (pi is null)
            return jsonRPCResult(msg, emptyJSONArray());

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        uint byteOffset = positionToByteOffset(pos, sourceText);

        // Find declaration at cursor
        import ast.expressions : IdentifierExpression;
        import ast.nodes : Declaration;

        auto expr = pi.findExprAt(byteOffset);
        Declaration target;

        if (auto ident = cast(IdentifierExpression)expr)
            target = ident.declaration;

        // Also check if cursor is on a declaration itself
        if (target is null) {
            auto decl = pi.findDeclAt(byteOffset);
            if (decl !is null)
                target = decl;
        }

        if (target is null || target.references is null)
            return jsonRPCResult(msg, emptyJSONArray());

        // Build locations from references
        JSONValue[] locations;
        foreach (ref_; target.references) {
            auto loc = ref_.location;
            if (loc.filename.length == 0) continue;

            string refSource = "";
            if (exists(loc.filename))
                refSource = readText(loc.filename);

            auto lspLoc = Location(
                pathToURI(loc.filename),
                sourceLocationToRange(loc.startOffset, loc.endOffset, refSource)
            );
            locations ~= lspLoc.toJSON();
        }

        return jsonRPCResult(msg, JSONValue(locations));
    }

    private JSONValue handleCompletion(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        auto pos = Position.fromJSON(params["position"]);

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        if (sourceText.length == 0 && exists(path))
            sourceText = readText(path);

        uint byteOffset = positionToByteOffset(pos, sourceText);

        JSONValue[] items;

        // Check import contexts first (before member-access detection)
        auto importCtx = detectImportContext(sourceText, byteOffset);
        if (importCtx !is null) {
            items = discoverModulePaths(importCtx);

            JSONValue result;
            result["isIncomplete"] = false;
            result["items"] = JSONValue(items);
            return jsonRPCResult(msg, result);
        }

        auto selectiveCtx = detectSelectiveImportContext(sourceText, byteOffset);
        if (!selectiveCtx.isNull) {
            auto exports = getModuleExports(selectiveCtx.get.modulePath);
            string selPrefix = selectiveCtx.get.prefix;
            foreach (ref item; exports) {
                if (selPrefix.length == 0 || item["label"].str.startsWith(selPrefix))
                    items ~= item;
            }

            JSONValue result;
            result["isIncomplete"] = false;
            result["items"] = JSONValue(items);
            return jsonRPCResult(msg, result);
        }

        // Determine completion context: member access (obj.) or identifier
        bool isMemberAccess = false;
        if (byteOffset > 0 && sourceText[byteOffset - 1] == '.')
            isMemberAccess = true;

        if (isMemberAccess) {
            // Member completion: find the expression before the dot,
            // resolve its type, iterate childIndex
            auto pi = absPath in positionIndexes;
            if (pi !is null) {
                // Find expression just before the dot
                auto expr = pi.findExprAt(byteOffset - 2);
                if (expr !is null) {
                    auto typedExpr = cast(Expression)expr;
                    if (typedExpr !is null && typedExpr.type !is null) {
                        // Resolve to struct/class declaration
                        if (auto userType = cast(UserType)typedExpr.type) {
                            if (userType.declaration !is null) {
                                auto decl = userType.declaration;
                                // Use childIndex for O(1) member enumeration
                                foreach (name, child; decl.childIndex) {
                                    items ~= makeCompletionItem(name, child);
                                }
                                // Also check members directly (fields + methods)
                                if (auto aggDecl = cast(AggregateDecl)decl) {
                                    foreach (member; aggDecl.members) {
                                        if (member.name.length > 0
                                            && member.name !in decl.childIndex)
                                        {
                                            items ~= makeCompletionItem(member.name, member);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            // Identifier completion: collect symbols from module scope
            auto mod = findModule(absPath);

            if (mod !is null && mod.symbolTable !is null) {
                // Get prefix (characters before cursor on current line)
                string prefix = "";
                if (byteOffset > 0) {
                    size_t start = byteOffset;
                    while (start > 0 && isIdentChar(sourceText[start - 1]))
                        start--;
                    prefix = sourceText[start .. byteOffset];
                }

                // Iterate module scope symbols, filter by prefix
                auto moduleScope = mod.symbolTable.moduleScope;
                if (moduleScope !is null) {
                    import semantic.symbol_table : Symbol;
                    foreach (name, sym; moduleScope.symbols) {
                        if (prefix.length == 0 || name.startsWith(prefix)) {
                            items ~= makeCompletionItemFromSymbol(name, sym);
                        }
                    }
                }
            }

            // Also add symbols from topIndex
            if (mod !is null && mod.topIndex.length > 0) {
                foreach (name, decl; mod.topIndex) {
                    // Avoid duplicates (already in module scope)
                    if (items.length > 100) break;  // cap for performance
                    // prefix filter
                    string prefix2 = "";
                    if (byteOffset > 0) {
                        size_t start = byteOffset;
                        while (start > 0 && isIdentChar(sourceText[start - 1]))
                            start--;
                        prefix2 = sourceText[start .. byteOffset];
                    }
                    if (prefix2.length > 0 && !name.startsWith(prefix2))
                        continue;
                }
            }
        }

        JSONValue result;
        result["isIncomplete"] = false;
        result["items"] = JSONValue(items);
        return jsonRPCResult(msg, result);
    }

    private JSONValue makeCompletionItem(string name, Declaration decl) {
        JSONValue item;
        item["label"] = name;

        // Determine kind and detail
        if (auto funcDecl = cast(FunctionDecl)decl) {
            item["kind"] = cast(int)CompletionItemKind.Function;
            // Build signature detail: "returnType(paramTypes)"
            string detail = funcDecl.returnType !is null ? funcDecl.returnType.toString() : "void";
            detail ~= "(";
            foreach (i, param; funcDecl.parameters) {
                if (i > 0) detail ~= ", ";
                detail ~= param.type !is null ? param.type.toString() : "?";
            }
            detail ~= ")";
            item["detail"] = detail;
        } else if (auto structDecl = cast(StructDecl)decl) {
            item["kind"] = cast(int)CompletionItemKind.Struct;
            auto fieldCount = structDecl.fields.length;
            item["detail"] = "struct (" ~ to!string(fieldCount) ~ " fields)";
        } else if (auto classDecl = cast(ClassDecl)decl) {
            item["kind"] = cast(int)CompletionItemKind.Class;
            string detail = "class";
            if (classDecl.baseClassDecl !is null)
                detail ~= " : " ~ classDecl.baseClassDecl.name;
            item["detail"] = detail;
        } else if (auto varDecl = cast(VariableDecl)decl) {
            item["kind"] = cast(int)CompletionItemKind.Field;
            if (varDecl.type !is null)
                item["detail"] = varDecl.type.toString();
        } else if (auto manifest = cast(ManifestConstantDecl)decl) {
            item["kind"] = cast(int)CompletionItemKind.Constant;
            string detail = "enum";
            if (manifest.inferredType !is null)
                detail = manifest.inferredType.toString();
            else if (manifest.declaredType !is null)
                detail = manifest.declaredType.toString();
            item["detail"] = detail;
        } else {
            item["kind"] = cast(int)CompletionItemKind.Variable;
        }

        return item;
    }

    private JSONValue makeCompletionItemFromSymbol(string name, Object symObj) {
        import semantic.symbol_table : Symbol, SymbolKind;
        auto sym = cast(Symbol)symObj;
        if (sym is null) return JSONValue(null);

        JSONValue item;
        item["label"] = name;

        final switch (sym.kind) {
            case SymbolKind.Function:
                item["kind"] = cast(int)CompletionItemKind.Function;
                break;
            case SymbolKind.Type:
                item["kind"] = cast(int)CompletionItemKind.Struct;
                break;
            case SymbolKind.Variable:
                item["kind"] = cast(int)CompletionItemKind.Variable;
                break;
            case SymbolKind.Parameter:
                item["kind"] = cast(int)CompletionItemKind.Variable;
                break;
            case SymbolKind.Field:
                item["kind"] = cast(int)CompletionItemKind.Field;
                break;
            case SymbolKind.Template:
                item["kind"] = cast(int)CompletionItemKind.Function;
                break;
        }

        // Add type detail if available
        if (sym.type !is null)
            item["detail"] = sym.type.toString();

        return item;
    }

    private static bool isIdentChar(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9') || c == '_';
    }

    // ── Import Completion Helpers ──

    /// Detect if cursor is inside an import path (e.g. `import std.`).
    /// Returns partial path components, or null if not in import context.
    /// Examples: "import " → [""], "import std." → ["std", ""], "import std.al" → ["std", "al"]
    private string[] detectImportContext(string sourceText, uint byteOffset) {
        if (byteOffset == 0 || sourceText.length == 0)
            return null;

        // Find the start of the current line
        size_t lineStart = byteOffset;
        while (lineStart > 0 && sourceText[lineStart - 1] != '\n')
            lineStart--;

        string line = sourceText[lineStart .. byteOffset];

        // Strip leading whitespace
        string trimmed = line.stripLeft();

        // Strip optional 'static ' prefix
        if (trimmed.startsWith("static "))
            trimmed = trimmed["static ".length .. $].stripLeft();

        // Must start with 'import '
        if (!trimmed.startsWith("import "))
            return null;

        string afterImport = trimmed["import ".length .. $].stripLeft();

        // If there's a ':' it's a selective import context (Milestone 2)
        if (afterImport.indexOf(':') >= 0)
            return null;

        // Split on '.' to get path components
        // "std." → ["std", ""], "std.al" → ["std", "al"], "" → [""]
        if (afterImport.length == 0)
            return [""];

        return afterImport.split(".");
    }

    /// Detect if cursor is after ':' in a selective import (e.g. `import foo : ba`).
    /// Returns the module path and the prefix being typed, or null.
    private auto detectSelectiveImportContext(string sourceText, uint byteOffset) {
        static struct SelectiveImportContext {
            string[] modulePath;
            string prefix;
        }

        if (byteOffset == 0 || sourceText.length == 0)
            return Nullable!SelectiveImportContext.init;

        // Find the start of the current line
        size_t lineStart = byteOffset;
        while (lineStart > 0 && sourceText[lineStart - 1] != '\n')
            lineStart--;

        string line = sourceText[lineStart .. byteOffset];
        string trimmed = line.stripLeft();

        if (trimmed.startsWith("static "))
            trimmed = trimmed["static ".length .. $].stripLeft();

        if (!trimmed.startsWith("import "))
            return Nullable!SelectiveImportContext.init;

        string afterImport = trimmed["import ".length .. $].stripLeft();

        auto colonIdx = afterImport.indexOf(':');
        if (colonIdx < 0)
            return Nullable!SelectiveImportContext.init;

        // Module path is before the colon
        string modPart = afterImport[0 .. colonIdx].strip();
        string afterColon = afterImport[colonIdx + 1 .. $].stripLeft();

        // Handle comma-separated selective imports: "bar, ba" → prefix is "ba"
        auto lastComma = afterColon.lastIndexOf(',');
        string prefix;
        if (lastComma >= 0)
            prefix = afterColon[lastComma + 1 .. $].stripLeft();
        else
            prefix = afterColon;

        // Trim trailing spaces from prefix (it's what user is typing)
        // but keep it as-is for prefix matching

        auto modulePath = modPart.split(".");
        if (modulePath.length == 0)
            return Nullable!SelectiveImportContext.init;

        return Nullable!SelectiveImportContext(SelectiveImportContext(modulePath, prefix));
    }

    /// Scan import search paths for modules/packages matching a partial import path.
    private JSONValue[] discoverModulePaths(string[] partialPath) {
        JSONValue[] items;
        bool[string] seen; // deduplicate across search paths

        // Directory components (all but last) and prefix filter (last)
        string[] dirParts = partialPath.length > 1 ? partialPath[0 .. $ - 1] : [];
        string prefix = partialPath[$ - 1];

        foreach (searchPath; importPaths) {
            // Build the subdirectory to scan
            string scanDir = searchPath;
            foreach (part; dirParts)
                scanDir = buildPath(scanDir, part);

            if (!exists(scanDir) || !isDir(scanDir))
                continue;

            try {
                foreach (entry; dirEntries(scanDir, SpanMode.shallow)) {
                    string name = baseName(entry.name);

                    if (entry.isDir) {
                        // Skip hidden directories
                        if (name.startsWith("."))
                            continue;
                        if (prefix.length > 0 && !name.startsWith(prefix))
                            continue;
                        if (name in seen)
                            continue;
                        seen[name] = true;

                        JSONValue item;
                        item["label"] = name;

                        // Check if this package has a package.d
                        if (exists(buildPath(entry.name, "package.d"))) {
                            item["kind"] = cast(int) CompletionItemKind.Module;
                            item["detail"] = "package module";
                        } else {
                            item["kind"] = cast(int) CompletionItemKind.Folder;
                            item["detail"] = "package";
                        }
                        item["sortText"] = "0_" ~ name; // packages sort first
                        items ~= item;
                    } else if (entry.isFile && name.endsWith(".d")) {
                        string modName = name[0 .. $ - 2]; // strip .d
                        if (modName == "package")
                            continue; // handled by directory entry above
                        if (prefix.length > 0 && !modName.startsWith(prefix))
                            continue;
                        if (modName in seen)
                            continue;
                        seen[modName] = true;

                        JSONValue item;
                        item["label"] = modName;
                        item["kind"] = cast(int) CompletionItemKind.Module;
                        item["sortText"] = "1_" ~ modName; // modules after packages

                        // Build full dotted path for detail
                        string fullPath = (dirParts ~ modName).join(".");
                        item["detail"] = fullPath;

                        items ~= item;
                    }
                }
            } catch (Exception e) {
                // Skip inaccessible directories
                continue;
            }
        }

        return items;
    }

    /// Look up a module from the warm state and return its exported declarations.
    private JSONValue[] getModuleExports(string[] modulePath) {
        JSONValue[] items;

        if (warmState.moduleRegistry is null)
            return items;

        import semantic.module_ : Module;
        string fqn = modulePath.join(".");
        auto mod = warmState.moduleRegistry.lookupModule(fqn);
        if (mod is null)
            return items;

        // Prefer topIndex (populated during symbol collection)
        if (mod.topIndex.length > 0) {
            foreach (name, decl; mod.topIndex) {
                if (name.length == 0)
                    continue;
                items ~= makeCompletionItem(name, decl);
            }
        } else if (mod.symbolTable !is null && mod.symbolTable.moduleScope !is null) {
            import semantic.symbol_table : Symbol;
            foreach (name, sym; mod.symbolTable.moduleScope.symbols) {
                if (name.length == 0)
                    continue;
                items ~= makeCompletionItemFromSymbol(name, sym);
            }
        }

        return items;
    }

    // ── Code Lens ──

    private JSONValue handleCodeLens(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        import semantic.module_ : Module;

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        if (sourceText.length == 0 && exists(path))
            sourceText = readText(path);

        Module mod = findModule(absPath);
        if (mod is null || mod.topIndex is null)
            return jsonRPCResult(msg, emptyJSONArray());

        JSONValue[] lenses;
        foreach (name, decl; mod.topIndex) {
            if (decl is null || decl.name.length == 0) continue;
            auto refCount = decl.references !is null ? decl.references.length : 0;
            auto range = sourceLocationToRange(
                decl.location.startOffset, decl.location.endOffset, sourceText);

            CodeLens lens;
            lens.range = range;
            lens.commandTitle = to!string(refCount) ~ " reference" ~ (refCount != 1 ? "s" : "");
            lens.commandName = "d2wasm.showReferences";
            lenses ~= lens.toJSON();

            // Also add lenses for children (methods, fields)
            foreach (childName, child; decl.childIndex) {
                if (child is null || child.name.length == 0) continue;
                auto childRefs = child.references !is null ? child.references.length : 0;
                auto childRange = sourceLocationToRange(
                    child.location.startOffset, child.location.endOffset, sourceText);

                CodeLens childLens;
                childLens.range = childRange;
                childLens.commandTitle = to!string(childRefs) ~ " reference" ~ (childRefs != 1 ? "s" : "");
                childLens.commandName = "d2wasm.showReferences";
                lenses ~= childLens.toJSON();
            }
        }

        return jsonRPCResult(msg, JSONValue(lenses));
    }

    // ── Semantic Tokens ──

    private JSONValue handleSemanticTokensFull(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        auto ppi = absPath in positionIndexes;
        if (ppi is null)
            return jsonRPCResult(msg, JSONValue(null));

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        if (sourceText.length == 0 && exists(path))
            sourceText = readText(path);

        import ast.expressions : IdentifierExpression, MemberExpression,
            LiteralExpression, CallExpression;

        // Build delta-encoded token data
        uint[] data;
        uint prevLine = 0;
        uint prevChar = 0;

        foreach (ref entry; ppi.allEntries()) {
            SemanticTokenType tokenType;
            uint modifiers = 0;
            bool matched = false;

            if (auto ident = cast(IdentifierExpression)entry.node) {
                matched = true;
                if (ident.declaration !is null) {
                    if (cast(FunctionDecl)ident.declaration) {
                        tokenType = SemanticTokenType.function_;
                    } else if (cast(StructDecl)ident.declaration) {
                        tokenType = SemanticTokenType.struct_;
                    } else if (cast(ClassDecl)ident.declaration) {
                        tokenType = SemanticTokenType.class_;
                    } else if (cast(EnumDecl)ident.declaration) {
                        tokenType = SemanticTokenType.enum_;
                    } else if (cast(ManifestConstantDecl)ident.declaration) {
                        tokenType = SemanticTokenType.variable;
                        modifiers = 1 << SemanticTokenModifier.readonly_;
                    } else if (cast(TemplateDecl)ident.declaration) {
                        tokenType = SemanticTokenType.function_;
                    } else {
                        tokenType = SemanticTokenType.variable;
                    }
                } else {
                    tokenType = SemanticTokenType.variable;
                }
            } else if (auto member = cast(MemberExpression)entry.node) {
                // Classify member access — property or method
                matched = true;
                tokenType = SemanticTokenType.property;

                // Check if it's a method by looking at the object type
                if (member.object !is null) {
                    auto typedObj = cast(Expression)member.object;
                    if (typedObj !is null && typedObj.type !is null) {
                        if (auto ut = cast(UserType)typedObj.type) {
                            if (ut.declaration !is null) {
                                if (auto child = member.memberName in ut.declaration.childIndex) {
                                    if (cast(FunctionDecl)*child)
                                        tokenType = SemanticTokenType.method;
                                }
                            }
                        }
                    }
                }
            }

            if (!matched) continue;

            // Compute line/character from byte offset
            uint startLine = 0, startChar = 0;
            uint line = 0, col = 0;
            foreach (i, c; sourceText) {
                if (i == entry.startByte) {
                    startLine = line;
                    startChar = col;
                    break;
                }
                if (c == '\n') { line++; col = 0; }
                else col++;
            }

            uint length = entry.endByte - entry.startByte;
            if (length == 0) continue;

            // Delta encoding
            uint deltaLine = startLine - prevLine;
            uint deltaChar = (deltaLine == 0) ? startChar - prevChar : startChar;

            data ~= deltaLine;
            data ~= deltaChar;
            data ~= length;
            data ~= cast(uint)tokenType;
            data ~= modifiers;

            prevLine = startLine;
            prevChar = startChar;
        }

        JSONValue result;
        JSONValue[] dataJSON;
        foreach (d; data)
            dataJSON ~= JSONValue(d);
        result["data"] = JSONValue(dataJSON);
        return jsonRPCResult(msg, result);
    }

    // ── Call Hierarchy ──

    private JSONValue handlePrepareCallHierarchy(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        auto pos = Position.fromJSON(params["position"]);

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        auto ppi = absPath in positionIndexes;
        if (ppi is null)
            return jsonRPCResult(msg, emptyJSONArray());

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        uint byteOffset = positionToByteOffset(pos, sourceText);

        // Find function declaration at cursor
        FunctionDecl funcDecl;

        // Try expression (identifier referencing a function)
        import ast.expressions : IdentifierExpression;
        auto expr = ppi.findExprAt(byteOffset);
        if (auto ident = cast(IdentifierExpression)expr)
            funcDecl = cast(FunctionDecl)ident.declaration;

        // Try declaration directly
        if (funcDecl is null) {
            auto decl = ppi.findDeclAt(byteOffset);
            funcDecl = cast(FunctionDecl)decl;
        }

        if (funcDecl is null)
            return jsonRPCResult(msg, emptyJSONArray());

        auto range = sourceLocationToRange(
            funcDecl.location.startOffset, funcDecl.location.endOffset, sourceText);

        CallHierarchyItem item;
        item.name = funcDecl.name;
        item.kind = cast(int)LSPSymbolKind.Function;
        item.uri = uri;
        item.range = range;
        item.selectionRange = range;

        return jsonRPCResult(msg, JSONValue([item.toJSON()]));
    }

    private JSONValue handleCallHierarchyIncoming(JSONValue msg) {
        auto params = msg["params"];
        auto itemJSON = params["item"];
        string uri = itemJSON["uri"].str;
        string targetName = itemJSON["name"].str;
        auto targetRange = Range.fromJSON(itemJSON["range"]);

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        // Find the target function declaration
        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        if (sourceText.length == 0 && exists(path))
            sourceText = readText(path);

        uint byteOffset = positionToByteOffset(targetRange.start, sourceText);

        auto ppi = absPath in positionIndexes;
        if (ppi is null)
            return jsonRPCResult(msg, emptyJSONArray());

        FunctionDecl targetFunc;
        auto decl = ppi.findDeclAt(byteOffset);
        targetFunc = cast(FunctionDecl)decl;

        // Also try via expression
        if (targetFunc is null) {
            import ast.expressions : IdentifierExpression;
            auto expr = ppi.findExprAt(byteOffset);
            if (auto ident = cast(IdentifierExpression)expr)
                targetFunc = cast(FunctionDecl)ident.declaration;
        }

        if (targetFunc is null || targetFunc.references is null)
            return jsonRPCResult(msg, emptyJSONArray());

        // Walk references to find call sites and their enclosing functions
        import ast.expressions : CallExpression;

        JSONValue[] incomingCalls;
        FunctionDecl[string] seenCallers;  // dedup by name

        foreach (ref_; targetFunc.references) {
            // Find the enclosing function for this reference
            auto enclosingFunc = findEnclosingFunction(ref_.location, absPath);
            if (enclosingFunc is null) continue;
            if (enclosingFunc.name in seenCallers) continue;
            seenCallers[enclosingFunc.name] = enclosingFunc;

            string callerSource = sourceText;  // same file for now
            auto callerRange = sourceLocationToRange(
                enclosingFunc.location.startOffset,
                enclosingFunc.location.endOffset, callerSource);

            CallHierarchyItem callerItem;
            callerItem.name = enclosingFunc.name;
            callerItem.kind = cast(int)LSPSymbolKind.Function;
            callerItem.uri = uri;
            callerItem.range = callerRange;
            callerItem.selectionRange = callerRange;

            // Build the call site range
            auto fromRange = sourceLocationToRange(
                ref_.location.startOffset, ref_.location.endOffset, callerSource);

            JSONValue incoming;
            incoming["from"] = callerItem.toJSON();
            incoming["fromRanges"] = JSONValue([fromRange.toJSON()]);
            incomingCalls ~= incoming;
        }

        return jsonRPCResult(msg, JSONValue(incomingCalls));
    }

    private JSONValue handleCallHierarchyOutgoing(JSONValue msg) {
        auto params = msg["params"];
        auto itemJSON = params["item"];
        string uri = itemJSON["uri"].str;
        auto targetRange = Range.fromJSON(itemJSON["range"]);

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        if (sourceText.length == 0 && exists(path))
            sourceText = readText(path);

        uint byteOffset = positionToByteOffset(targetRange.start, sourceText);

        auto ppi = absPath in positionIndexes;
        if (ppi is null)
            return jsonRPCResult(msg, emptyJSONArray());

        FunctionDecl targetFunc;
        auto decl = ppi.findDeclAt(byteOffset);
        targetFunc = cast(FunctionDecl)decl;

        if (targetFunc is null)
            return jsonRPCResult(msg, emptyJSONArray());

        // Walk the function body to find all call expressions
        import ast.expressions : CallExpression, IdentifierExpression,
            BinaryExpression, UnaryExpression, AssignmentExpression,
            CastExpression, IndexExpression, MemberExpression;

        JSONValue[] outgoingCalls;
        FunctionDecl[string] seenCallees;

        // findCallsInExpr defined first (D has no nested function forward refs)
        void findCallsInExpr(Expression expr) {
            if (expr is null) return;

            if (auto call = cast(CallExpression)expr) {
                FunctionDecl callee;
                if (auto ident = cast(IdentifierExpression)call.function_)
                    callee = cast(FunctionDecl)ident.declaration;
                if (callee !is null && callee.name !in seenCallees) {
                    seenCallees[callee.name] = callee;

                    auto calleeRange = sourceLocationToRange(
                        callee.location.startOffset,
                        callee.location.endOffset, sourceText);

                    CallHierarchyItem calleeItem;
                    calleeItem.name = callee.name;
                    calleeItem.kind = cast(int)LSPSymbolKind.Function;
                    calleeItem.uri = callee.location.filename.length > 0
                        ? pathToURI(callee.location.filename) : uri;
                    calleeItem.range = calleeRange;
                    calleeItem.selectionRange = calleeRange;

                    auto callRange = sourceLocationToRange(
                        call.location.startOffset,
                        call.location.endOffset, sourceText);

                    JSONValue outgoing;
                    outgoing["to"] = calleeItem.toJSON();
                    outgoing["fromRanges"] = JSONValue([callRange.toJSON()]);
                    outgoingCalls ~= outgoing;
                }
                foreach (arg; call.arguments) findCallsInExpr(arg);
                findCallsInExpr(call.function_);
            } else if (auto bin = cast(BinaryExpression)expr) {
                findCallsInExpr(bin.left);
                findCallsInExpr(bin.right);
            } else if (auto unary = cast(UnaryExpression)expr) {
                findCallsInExpr(unary.operand);
            } else if (auto assign = cast(AssignmentExpression)expr) {
                findCallsInExpr(assign.left);
                findCallsInExpr(assign.right);
            } else if (auto castExpr = cast(CastExpression)expr) {
                findCallsInExpr(castExpr.expression);
            } else if (auto indexExpr = cast(IndexExpression)expr) {
                findCallsInExpr(indexExpr.array);
                findCallsInExpr(indexExpr.index);
            } else if (auto memberExpr = cast(MemberExpression)expr) {
                findCallsInExpr(memberExpr.object);
            }
        }

        void walkForCalls(Statement stmt) {
            if (stmt is null) return;

            if (auto compound = cast(CompoundStatement)stmt) {
                foreach (s; compound.statements) walkForCalls(s);
            } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
                findCallsInExpr(exprStmt.expression);
            } else if (auto retStmt = cast(ReturnStatement)stmt) {
                if (retStmt.value) findCallsInExpr(retStmt.value);
            } else if (auto ifStmt = cast(IfStatement)stmt) {
                findCallsInExpr(ifStmt.condition);
                walkForCalls(ifStmt.thenStatement);
                if (ifStmt.elseStatement) walkForCalls(ifStmt.elseStatement);
            } else if (auto whileStmt = cast(WhileStatement)stmt) {
                findCallsInExpr(whileStmt.condition);
                walkForCalls(whileStmt.body_);
            } else if (auto forStmt = cast(ForStatement)stmt) {
                if (forStmt.init) walkForCalls(forStmt.init);
                if (forStmt.condition) findCallsInExpr(forStmt.condition);
                if (forStmt.update) findCallsInExpr(forStmt.update);
                walkForCalls(forStmt.body_);
            } else if (auto varDeclStmt = cast(VariableDeclarationStatement)stmt) {
                if (varDeclStmt.initializer) findCallsInExpr(varDeclStmt.initializer);
            }
        }

        if (targetFunc.body_)
            walkForCalls(targetFunc.body_);

        return jsonRPCResult(msg, JSONValue(outgoingCalls));
    }

    // ── Type Hierarchy ──

    private JSONValue handlePrepareTypeHierarchy(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        auto pos = Position.fromJSON(params["position"]);

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        auto ppi = absPath in positionIndexes;
        if (ppi is null)
            return jsonRPCResult(msg, emptyJSONArray());

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        uint byteOffset = positionToByteOffset(pos, sourceText);

        // Find class/interface/struct at cursor
        Declaration target;
        auto decl = ppi.findDeclAt(byteOffset);
        if (cast(ClassDecl)decl || cast(StructDecl)decl)
            target = decl;

        // Also try via expression (identifier referencing a type)
        if (target is null) {
            import ast.expressions : IdentifierExpression;
            auto expr = ppi.findExprAt(byteOffset);
            if (auto ident = cast(IdentifierExpression)expr) {
                if (cast(ClassDecl)ident.declaration || cast(StructDecl)ident.declaration)
                    target = ident.declaration;
            }
        }

        if (target is null)
            return jsonRPCResult(msg, emptyJSONArray());

        auto range = sourceLocationToRange(
            target.location.startOffset, target.location.endOffset, sourceText);

        int kind = cast(ClassDecl)target ? cast(int)LSPSymbolKind.Class : cast(int)LSPSymbolKind.Struct;

        TypeHierarchyItem item;
        item.name = target.name;
        item.kind = kind;
        item.uri = uri;
        item.range = range;
        item.selectionRange = range;

        return jsonRPCResult(msg, JSONValue([item.toJSON()]));
    }

    private JSONValue handleTypeHierarchySupertypes(JSONValue msg) {
        auto params = msg["params"];
        auto itemJSON = params["item"];
        string uri = itemJSON["uri"].str;
        string targetName = itemJSON["name"].str;

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        if (sourceText.length == 0 && exists(path))
            sourceText = readText(path);

        // Find the class declaration by name
        import semantic.module_ : Module;
        ClassDecl classDecl = findClassByName(targetName);

        if (classDecl is null)
            return jsonRPCResult(msg, emptyJSONArray());

        JSONValue[] supertypes;

        // Add base class
        if (classDecl.baseClassDecl !is null) {
            auto base = classDecl.baseClassDecl;
            string baseSrc = "";
            string baseUri = uri;
            if (base.location.filename.length > 0) {
                baseUri = pathToURI(base.location.filename);
                if (exists(base.location.filename))
                    baseSrc = readText(base.location.filename);
            }

            auto baseRange = sourceLocationToRange(
                base.location.startOffset, base.location.endOffset,
                baseSrc.length > 0 ? baseSrc : sourceText);

            TypeHierarchyItem superItem;
            superItem.name = base.name;
            superItem.kind = cast(int)LSPSymbolKind.Class;
            superItem.uri = baseUri;
            superItem.range = baseRange;
            superItem.selectionRange = baseRange;
            supertypes ~= superItem.toJSON();
        }

        return jsonRPCResult(msg, JSONValue(supertypes));
    }

    private JSONValue handleTypeHierarchySubtypes(JSONValue msg) {
        auto params = msg["params"];
        auto itemJSON = params["item"];
        string targetName = itemJSON["name"].str;

        // Scan all modules for classes that extend the target
        import semantic.module_ : Module;

        JSONValue[] subtypes;

        if (warmState.moduleRegistry !is null) {
            foreach (mod; warmState.moduleRegistry.allModules()) {
                foreach (name, decl; mod.topIndex) {
                    if (auto classDecl = cast(ClassDecl)decl) {
                        if (classDecl.baseClassDecl !is null
                            && classDecl.baseClassDecl.name == targetName)
                        {
                            string subSrc = "";
                            string subUri;
                            if (classDecl.location.filename.length > 0) {
                                subUri = pathToURI(classDecl.location.filename);
                                if (exists(classDecl.location.filename))
                                    subSrc = readText(classDecl.location.filename);
                            }

                            auto subRange = sourceLocationToRange(
                                classDecl.location.startOffset,
                                classDecl.location.endOffset,
                                subSrc);

                            TypeHierarchyItem subItem;
                            subItem.name = classDecl.name;
                            subItem.kind = cast(int)LSPSymbolKind.Class;
                            subItem.uri = subUri;
                            subItem.range = subRange;
                            subItem.selectionRange = subRange;
                            subtypes ~= subItem.toJSON();
                        }
                    }
                }
            }
        }

        return jsonRPCResult(msg, JSONValue(subtypes));
    }

    // ── Rename ──

    private JSONValue handlePrepareRename(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        auto pos = Position.fromJSON(params["position"]);

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        auto ppi = absPath in positionIndexes;
        if (ppi is null)
            return jsonRPCResult(msg, JSONValue(null));

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        uint byteOffset = positionToByteOffset(pos, sourceText);

        // Find the declaration to rename
        import ast.expressions : IdentifierExpression;

        Declaration target;
        string targetName;

        auto expr = ppi.findExprAt(byteOffset);
        if (auto ident = cast(IdentifierExpression)expr) {
            target = ident.declaration;
            targetName = ident.name;
        }

        if (target is null) {
            auto decl = ppi.findDeclAt(byteOffset);
            if (decl !is null) {
                target = decl;
                targetName = decl.name;
            }
        }

        if (target is null || targetName.length == 0)
            return jsonRPCResult(msg, JSONValue(null));

        // Return the range of the identifier under cursor
        auto range = sourceLocationToRange(
            expr !is null ? expr.location.startOffset : target.location.startOffset,
            expr !is null ? expr.location.endOffset : target.location.endOffset,
            sourceText);

        JSONValue result;
        result["range"] = range.toJSON();
        result["placeholder"] = targetName;
        return jsonRPCResult(msg, result);
    }

    private JSONValue handleRename(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        auto pos = Position.fromJSON(params["position"]);
        string newName = params["newName"].str;

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        auto ppi = absPath in positionIndexes;
        if (ppi is null)
            return jsonRPCResult(msg, JSONValue(null));

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        uint byteOffset = positionToByteOffset(pos, sourceText);

        // Find the declaration to rename
        import ast.expressions : IdentifierExpression;

        Declaration target;
        auto expr = ppi.findExprAt(byteOffset);
        if (auto ident = cast(IdentifierExpression)expr)
            target = ident.declaration;

        if (target is null) {
            auto decl = ppi.findDeclAt(byteOffset);
            if (decl !is null) target = decl;
        }

        if (target is null)
            return jsonRPCResult(msg, JSONValue(null));

        // Collect all edit locations
        // Group edits by file URI
        TextEdit[][string] editsByUri;

        // Edit at the declaration site itself
        if (target.location.filename.length > 0) {
            string declUri = pathToURI(target.location.filename);
            string declSrc = "";
            if (exists(target.location.filename))
                declSrc = readText(target.location.filename);

            auto declRange = sourceLocationToRange(
                target.location.startOffset, target.location.endOffset, declSrc);

            TextEdit edit;
            edit.range = declRange;
            edit.newText = newName;
            editsByUri[declUri] ~= edit;
        }

        // Edit at all reference sites
        if (target.references !is null) {
            foreach (ref_; target.references) {
                auto loc = ref_.location;
                if (loc.filename.length == 0) continue;

                string refUri = pathToURI(loc.filename);
                string refSrc = "";
                if (exists(loc.filename))
                    refSrc = readText(loc.filename);

                auto refRange = sourceLocationToRange(
                    loc.startOffset, loc.endOffset, refSrc);

                TextEdit edit;
                edit.range = refRange;
                edit.newText = newName;
                editsByUri[refUri] ~= edit;
            }
        }

        // Build WorkspaceEdit
        JSONValue changes;
        foreach (fileUri, edits; editsByUri) {
            JSONValue[] editJSONs;
            foreach (ref e; edits)
                editJSONs ~= e.toJSON();
            changes[fileUri] = JSONValue(editJSONs);
        }

        JSONValue result;
        result["changes"] = changes;
        return jsonRPCResult(msg, result);
    }

    // ── Workspace ──

    private void handleDidChangeWatchedFiles(JSONValue msg) {
        auto params = msg["params"];
        if ("changes" in params) {
            foreach (change; params["changes"].array) {
                string fileUri = change["uri"].str;
                string filePath = uriToPath(fileUri);
                auto absFilePath = absolutePath(filePath);

                // If this file is open in the editor, skip (editor handles it)
                if (fileUri in openDocuments) continue;

                // Mark file as dirty in warm state so next compile picks up changes
                if (exists(filePath) && filePath.length > 2
                    && filePath[$ - 2 .. $] == ".d")
                {
                    auto ws = warmState.getOrCreate(absFilePath);
                    // Clear cached data to force recompile
                    ws.cachedEntries = null;
                    lspLog("File changed on disk: ", filePath);
                }
            }
        }
    }

    private void handleDidChangeWorkspaceFolders(JSONValue msg) {
        auto params = msg["params"];
        if ("event" in params) {
            auto event = params["event"];
            // Add new workspace folders as import paths
            if ("added" in event) {
                foreach (folder; event["added"].array) {
                    string folderPath = uriToPath(folder["uri"].str);
                    if (folderPath.length > 0 && exists(folderPath)) {
                        bool alreadyHave = false;
                        foreach (ip; importPaths) {
                            if (ip == folderPath) { alreadyHave = true; break; }
                        }
                        if (!alreadyHave) {
                            importPaths ~= folderPath;
                            lspLog("Added workspace folder: ", folderPath);
                        }
                    }
                }
            }
            // Remove workspace folders from import paths
            if ("removed" in event) {
                foreach (folder; event["removed"].array) {
                    string folderPath = uriToPath(folder["uri"].str);
                    string[] filtered;
                    foreach (ip; importPaths) {
                        if (ip != folderPath) filtered ~= ip;
                    }
                    importPaths = filtered;
                    lspLog("Removed workspace folder: ", folderPath);
                }
            }
        }
    }

    // ── Code Actions ──

    private JSONValue handleCodeAction(JSONValue msg) {
        auto params = msg["params"];
        string uri = params["textDocument"]["uri"].str;
        auto requestRange = Range.fromJSON(params["range"]);

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        if (sourceText.length == 0 && exists(path))
            sourceText = readText(path);

        JSONValue[] actions;

        // Check diagnostics in the requested range for quickfix opportunities
        if ("context" in params && "diagnostics" in params["context"]) {
            foreach (diag; params["context"]["diagnostics"].array) {
                string diagMsg = diag["message"].str;

                // "Did you mean?" for undefined identifiers
                if (diagMsg.indexOf("Undefined identifier '") >= 0) {
                    // Extract the identifier name from the error message
                    auto quotePos = diagMsg.indexOf("'");
                    if (quotePos >= 0) {
                        auto start = cast(size_t)(quotePos + 1);
                        auto endRel = diagMsg[start .. $].indexOf("'");
                        if (endRel < 0) continue;
                        auto end = start + cast(size_t)endRel;
                        string badName = diagMsg[start .. end];
                        auto suggestions = findSimilarNames(badName, absPath);

                        foreach (suggestion; suggestions) {
                            auto diagRange = Range.fromJSON(diag["range"]);

                            JSONValue edit;
                            edit["range"] = diagRange.toJSON();
                            edit["newText"] = suggestion;

                            JSONValue changes;
                            changes[uri] = JSONValue([edit]);

                            JSONValue workspaceEdit;
                            workspaceEdit["changes"] = changes;

                            JSONValue action;
                            action["title"] = "Replace with '" ~ suggestion ~ "'";
                            action["kind"] = "quickfix";
                            action["diagnostics"] = JSONValue([diag]);
                            action["edit"] = workspaceEdit;
                            actions ~= action;
                        }
                    }
                }
            }
        }

        return jsonRPCResult(msg, JSONValue(actions));
    }

    /// Find names similar to `name` in the module's scope (Levenshtein distance <= 2)
    private string[] findSimilarNames(string name, string absPath) {
        import semantic.module_ : Module;

        string[] suggestions;
        auto mod = findModule(absPath);
        if (mod is null) return suggestions;

        // Collect candidate names from module scope and topIndex
        void checkCandidate(string candidate) {
            if (candidate == name) return;
            if (candidate.length == 0) return;
            auto dist = levenshtein(name, candidate);
            if (dist <= 2 && dist > 0)
                suggestions ~= candidate;
        }

        if (mod.symbolTable !is null && mod.symbolTable.moduleScope !is null) {
            foreach (sym_name, _; mod.symbolTable.moduleScope.symbols)
                checkCandidate(sym_name);
        }
        foreach (decl_name, _; mod.topIndex)
            checkCandidate(decl_name);

        // Sort by distance (shortest first), cap at 3
        if (suggestions.length > 3)
            suggestions = suggestions[0 .. 3];

        return suggestions;
    }

    /// Levenshtein edit distance between two strings
    private static uint levenshtein(string a, string b) {
        if (a.length == 0) return cast(uint)b.length;
        if (b.length == 0) return cast(uint)a.length;

        auto prev = new uint[b.length + 1];
        auto curr = new uint[b.length + 1];

        foreach (j; 0 .. b.length + 1)
            prev[j] = cast(uint)j;

        foreach (i; 0 .. a.length) {
            curr[0] = cast(uint)(i + 1);
            foreach (j; 0 .. b.length) {
                uint cost = (a[i] == b[j]) ? 0 : 1;
                uint del = prev[j + 1] + 1;
                uint ins = curr[j] + 1;
                uint sub = prev[j] + cost;
                curr[j + 1] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
            }
            auto tmp = prev;
            prev = curr;
            curr = tmp;
        }

        return prev[b.length];
    }

    // ── Helper: find module by path ──

    private auto findModule(string absPath) {
        import semantic.module_ : Module;
        if (warmState.moduleRegistry !is null) {
            foreach (m; warmState.moduleRegistry.allModules()) {
                if (m.sourceFilePath == absPath)
                    return m;
            }
        }
        return null;
    }

    /// Find enclosing function for a reference location
    private FunctionDecl findEnclosingFunction(SourceLocation loc, string absPath) {
        import semantic.module_ : Module;
        auto mod = findModule(absPath);
        if (mod is null) return null;

        // Walk top-level declarations to find the function containing this offset
        foreach (name, decl; mod.topIndex) {
            if (auto funcDecl = cast(FunctionDecl)decl) {
                if (funcDecl.location.startOffset <= loc.startOffset
                    && funcDecl.location.endOffset >= loc.endOffset)
                    return funcDecl;
            }
        }
        return null;
    }

    /// Find a ClassDecl by name across all modules
    private ClassDecl findClassByName(string name) {
        import semantic.module_ : Module;
        if (warmState.moduleRegistry is null) return null;

        foreach (mod; warmState.moduleRegistry.allModules()) {
            if (auto decl = name in mod.topIndex) {
                if (auto classDecl = cast(ClassDecl)*decl)
                    return classDecl;
            }
        }
        return null;
    }

    // ── Compilation + Diagnostics ──

    private void compileAndPublishDiagnostics(string uri, string sourceText) {
        import main : CompilerOptions, compileFile;

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        // Set up compile options — dry run (parse + type-check only, no codegen)
        CompilerOptions options;
        options.inputFile = path;
        options.outputFile = setExtension(path, ".wasm");
        options.backend = backend;
        options.dryRun = true;  // LSP only needs diagnostics, not code generation
        options.stackTrace = stackTrace;
        options.importPaths = importPaths.dup;
        options.verbosity = 0;  // suppress output

        // Wire warm state
        auto ws = warmState.getOrCreate(absPath);
        options.warmState = ws;
        options.warmStateObj = warmState;
        options.cacheDir = dirName(absPath);

        // Set up warning accumulator
        import diagnostic.warnings : Warning, WarningSeverity, warningsSink;
        Warning[] warnings;
        warningsSink = &warnings;
        scope(exit) warningsSink = null;

        // Compile
        Diagnostic[] diagnostics;
        ws.lastError = null;
        ws.lastErrors = null;
        int result = compileFile(options);

        // Extract diagnostics from compilation errors
        if (result != 0) {
            // Use accumulated errors if available, otherwise fall back to single error
            Exception[] errors = ws.lastErrors.length > 0 ? ws.lastErrors :
                (ws.lastError !is null ? [ws.lastError] : null);

            foreach (err; errors) {
                auto loc = extractLocation(err);
                diagnostics ~= Diagnostic(
                    sourceLocationToRange(loc.startOffset, loc.endOffset, sourceText),
                    DiagnosticSeverity.Error,
                    err.msg
                );
            }
        }

        // Add warnings (even on successful compilation)
        foreach (ref w; warnings) {
            diagnostics ~= Diagnostic(
                sourceLocationToRange(w.location.startOffset, w.location.endOffset, sourceText),
                cast(DiagnosticSeverity)w.severity,
                w.message
            );
        }

        // Build position index from compilation result
        import semantic.module_ : Module;
        if (warmState.moduleRegistry !is null) {
            foreach (mod; warmState.moduleRegistry.allModules()) {
                if (mod.sourceFilePath == absPath && mod.ast.length > 0) {
                    auto pi = new PositionIndex();
                    pi.build(mod.ast);
                    positionIndexes[absPath] = pi;
                    break;
                }
            }
        }

        // Publish diagnostics (empty array clears previous diagnostics on success)
        JSONValue[] diagJSONs;
        foreach (ref d; diagnostics)
            diagJSONs ~= d.toJSON();

        JSONValue diagParams;
        diagParams["uri"] = uri;
        diagParams["diagnostics"] = JSONValue(diagJSONs);
        sendNotification("textDocument/publishDiagnostics", diagParams);
    }

    /// Extract SourceLocation from error exceptions that carry location info.
    /// All d2wasm error types (ParseError, TypeError, SemanticError, etc.)
    /// have a .location field.
    private static SourceLocation extractLocation(Exception e) {
        // Use the .location field that all d2wasm error types share
        // (they all implement it via the printError template requirement)
        try {
            // Dynamic dispatch: check if the object has a location field
            if (auto obj = cast(Object)e) {
                // All our error types inherit from Exception and have .location
                // Use __traits or manual casting
                import parser.tree_sitter_bridge : ParseError;
                import semantic.symbol_table : SemanticError;
                import semantic.type_checker : TypeError;
                import semantic.ctfe : CTFEError;
                import codegen.emitter : EmitError;
                import semantic.import_resolver : ImportError;

                if (auto pe = cast(ParseError)e) return pe.location;
                if (auto se = cast(SemanticError)e) return se.location;
                if (auto te = cast(TypeError)e) return te.location;
                if (auto ce = cast(CTFEError)e) return ce.location;
                if (auto ee = cast(EmitError)e) return ee.location;
                if (auto ie = cast(ImportError)e) return ie.location;
            }
        } catch (Exception) {}
        return SourceLocation.init;
    }

    // ── Helpers ──

    private JSONValue declToDocumentSymbol(Declaration decl, string sourceText) {
        import ast.nodes : FunctionDecl, StructDecl, ClassDecl,
            VariableDecl, ManifestConstantDecl, EnumDecl, TemplateDecl, AggregateDecl;

        if (decl is null || decl.name.length == 0)
            return JSONValue(null);

        LSPSymbolKind kind;
        if (cast(FunctionDecl)decl) kind = LSPSymbolKind.Function;
        else if (cast(StructDecl)decl) kind = LSPSymbolKind.Struct;
        else if (cast(ClassDecl)decl) kind = LSPSymbolKind.Class;
        else if (cast(VariableDecl)decl) kind = LSPSymbolKind.Variable;
        else if (cast(ManifestConstantDecl)decl) kind = LSPSymbolKind.Constant;
        else if (cast(EnumDecl)decl) kind = LSPSymbolKind.Enum;
        else if (cast(TemplateDecl)decl) kind = LSPSymbolKind.Function;
        else kind = LSPSymbolKind.Variable;

        auto range = sourceLocationToRange(
            decl.location.startOffset, decl.location.endOffset, sourceText);

        JSONValue sym;
        sym["name"] = decl.name;
        sym["kind"] = cast(int)kind;
        sym["range"] = range.toJSON();
        sym["selectionRange"] = range.toJSON();

        // Add children from childIndex
        if (decl.childIndex.length > 0) {
            JSONValue[] children;
            foreach (childName, child; decl.childIndex) {
                auto childSym = declToDocumentSymbol(child, sourceText);
                if (!childSym.isNull)
                    children ~= childSym;
            }
            if (children.length > 0)
                sym["children"] = JSONValue(children);
        }

        return sym;
    }

    private static JSONValue jsonRPCResult(JSONValue request, JSONValue result) {
        JSONValue resp;
        resp["jsonrpc"] = "2.0";
        resp["id"] = request["id"];
        resp["result"] = result;
        return resp;
    }

    private static JSONValue jsonRPCError(JSONValue request, int code, string message) {
        JSONValue resp;
        resp["jsonrpc"] = "2.0";
        resp["id"] = request["id"];
        JSONValue err;
        err["code"] = code;
        err["message"] = message;
        resp["error"] = err;
        return resp;
    }

    private static JSONValue emptyJSONArray() {
        JSONValue v;
        v = cast(JSONValue[])null;
        return v;
    }

    private void lspLog(T...)(T args) {
        stderr.write("[d2wasm-lsp] ");
        stderr.writeln(args);
        stderr.flush();
    }
}
