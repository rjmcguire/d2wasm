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

import ast.nodes;
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
        string method = msg["method"].str;
        bool isRequest = "id" in msg ? true : false;

        lspLog("← ", method);

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
            default:
                if (isRequest)
                    return jsonRPCError(msg, -32601, "Method not found: " ~ method);
                return JSONValue(null);
        }
    }

    // ── LSP Handlers ──

    private JSONValue handleInitialize(JSONValue msg) {
        JSONValue caps;

        // Text document sync: full content on open/change
        caps["textDocumentSync"] = 1;  // Full sync

        // Features we support
        caps["definitionProvider"] = true;
        caps["hoverProvider"] = true;
        caps["documentSymbolProvider"] = true;
        caps["referencesProvider"] = true;

        JSONValue sigHelp;
        sigHelp["triggerCharacters"] = JSONValue(["("]);
        caps["signatureHelpProvider"] = sigHelp;

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

        // Full sync: take the last content change
        auto changes = params["contentChanges"].array;
        if (changes.length > 0)
            openDocuments[uri] = changes[$ - 1]["text"].str;
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

        auto pi = absPath in positionIndexes;
        if (pi is null)
            return jsonRPCResult(msg, JSONValue(null));

        string sourceText = (uri in openDocuments) ? openDocuments[uri] : "";
        uint byteOffset = positionToByteOffset(pos, sourceText);

        // Find the call expression at cursor
        import ast.expressions : CallExpression, IdentifierExpression;

        auto node = pi.findExprAt(byteOffset);
        auto call = cast(CallExpression)node;
        if (call is null)
            return jsonRPCResult(msg, JSONValue(null));

        // Resolve to FunctionDecl
        FunctionDecl funcDecl;
        if (auto ident = cast(IdentifierExpression)call.function_) {
            funcDecl = cast(FunctionDecl)ident.declaration;
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

        JSONValue sigInfo;
        sigInfo["label"] = sig;
        sigInfo["parameters"] = JSONValue(paramInfos);

        JSONValue result;
        result["signatures"] = JSONValue([sigInfo]);
        result["activeSignature"] = 0;
        result["activeParameter"] = 0;
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

        // Use warm state's module registry to find the module
        Module mod;
        if (warmState.moduleRegistry !is null) {
            foreach (m; warmState.moduleRegistry.allModules()) {
                if (m.sourceFilePath == absPath) {
                    mod = m;
                    break;
                }
            }
        }

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

    // ── Compilation + Diagnostics ──

    private void compileAndPublishDiagnostics(string uri, string sourceText) {
        import main : CompilerOptions, compileFile;

        string path = uriToPath(uri);
        auto absPath = absolutePath(path);

        // Set up compile options
        CompilerOptions options;
        options.inputFile = path;
        options.outputFile = setExtension(path, ".wasm");
        options.backend = backend;
        options.stackTrace = stackTrace;
        options.importPaths = importPaths.dup;
        options.verbosity = 0;  // suppress output

        // Wire warm state
        auto ws = warmState.getOrCreate(absPath);
        options.warmState = ws;
        options.warmStateObj = warmState;
        options.cacheDir = dirName(absPath);

        // Compile — capture stderr for diagnostics
        Diagnostic[] diagnostics;
        try {
            int result = compileFile(options);
            // Success — clear diagnostics
        } catch (Exception e) {
            // Extract location from exception if available
            auto loc = extractLocation(e);
            diagnostics ~= Diagnostic(
                sourceLocationToRange(
                    loc.startOffset, loc.endOffset, sourceText),
                DiagnosticSeverity.Error,
                e.msg
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

        // Publish diagnostics
        JSONValue[] diagJSONs;
        foreach (ref d; diagnostics)
            diagJSONs ~= d.toJSON();

        JSONValue params;
        params["uri"] = uri;
        params["diagnostics"] = JSONValue(diagJSONs);
        sendNotification("textDocument/publishDiagnostics", params);
    }

    private static auto extractLocation(Exception e) {
        import ast.nodes : SourceLocation;
        // Try to extract location from various error types
        static foreach (ErrorType; [
            "parser.tree_sitter_bridge.ParseError",
            "semantic.symbol_table.SemanticError",
            "semantic.type_checker.TypeError",
        ]) {
            // Use runtime type info
        }
        // Fallback: no location
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
