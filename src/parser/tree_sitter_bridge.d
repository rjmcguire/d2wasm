/**
 * Tree-sitter Bridge for D-to-WASM Compiler
 * 
 * This module provides the interface between tree-sitter's parse tree
 * and our semantic AST. It converts tree-sitter nodes into AST nodes
 * while handling error recovery and source location tracking.
 */
module parser.tree_sitter_bridge;

import ast.nodes;
import ast.statements;
import ast.expressions;
import parser.tree_sitter_c;
import std.string;
import std.conv;
import std.stdio;
import std.algorithm;
import diagnostic.log : log;

/**
 * Unescape a D string literal (handle \n, \t, \", \\, etc.)
 */
private string unescapeString(string s) {
    import std.array : Appender;
    
    Appender!string result;
    bool inEscape = false;
    
    foreach (c; s) {
        if (inEscape) {
            switch (c) {
                case 'n': result ~= '\n'; break;
                case 't': result ~= '\t'; break;
                case 'r': result ~= '\r'; break;
                case '0': result ~= '\0'; break;
                case '\\': result ~= '\\'; break;
                case '"': result ~= '"'; break;
                case '\'': result ~= '\''; break;
                default: result ~= c; break;
            }
            inEscape = false;
        } else if (c == '\\') {
            inEscape = true;
        } else {
            result ~= c;
        }
    }
    
    return result.data;
}

/**
 * Parse an integer literal, handling hex (0x), binary (0b), octal (0o), and decimal formats.
 * Also strips underscores (D allows 1_000_000).
 */
private long parseIntLiteral(string text) {
    import std.string : replace;
    import std.algorithm : startsWith;
    import std.conv : parse;
    
    // Strip underscores (D allows them for readability)
    string clean = text.replace("_", "");
    
    // Handle hex (0x/0X)
    if (clean.startsWith("0x") || clean.startsWith("0X")) {
        string digits = clean[2..$];
        return parse!long(digits, 16);
    }
    // Handle binary (0b/0B)
    if (clean.startsWith("0b") || clean.startsWith("0B")) {
        string digits = clean[2..$];
        return parse!long(digits, 2);
    }
    // Handle octal (0o) - D uses 0o prefix, not bare 0
    if (clean.startsWith("0o") || clean.startsWith("0O")) {
        string digits = clean[2..$];
        return parse!long(digits, 8);
    }
    // Decimal
    return parse!long(clean);
}

/**
 * Parser error with location information
 */
class ParseError : Exception {
    SourceLocation location;
    string hint;
    
    this(string message, SourceLocation location, string hint = "", string file = __FILE__, size_t line = __LINE__) {
        this.location = location;
        this.hint = hint;
        super(format("%s at %s%s", message, location.toString(), hint.length ? ": " ~ hint : ""), file, line);
    }
}

/**
 * Main bridge class that converts tree-sitter parse trees to AST
 */
class TreeSitterBridge {
    string filename;
    string sourceText;
    TreeSitterParser parser;
    
    this(string filename, string sourceText) {
        this.filename = filename;
        this.sourceText = sourceText;
        this.parser = new TreeSitterParser();
    }
    
    /**
     * Parse the source file and return AST declarations
     */
    Declaration[] parseSourceFile() {
        try {
            auto root = parser.parseString(sourceText);
            if (!TreeSitterParser.isValid(root)) {
                throw new ParseError("Invalid parse tree root", SourceLocation(filename, 1, 1, 0, 0));
            }
            return parseSourceFileNode(root);
        } catch (Exception e) {
            import std.stdio : writeln;
            writeln("Exception in parseSourceFile: ", e.msg);
            throw e;
        }
    }
    
    /**
     * Convert a tree-sitter parse tree root to our AST
     */
    Declaration[] parseSourceFileNode(TSNode root) {
        try {
            if (!TreeSitterParser.isValid(root)) {
                throw new ParseError("Invalid parse tree root", SourceLocation(filename, 1, 1, 0, 0));
            }
            
            if (TreeSitterParser.hasError(root)) {
                throw new ParseError("Parse errors in source file", SourceLocation(filename, 1, 1, 0, 0));
            }
            
            Declaration[] declarations;
            
            uint childCount = TreeSitterParser.getChildCount(root);
            log(3, "Root has ", childCount, " children");
            
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(root, i);
                if (!TreeSitterParser.isValid(child)) {
                    log(2, "Warning: Invalid child node at index ", i);
                    continue;
                }
                
                string nodeType = TreeSitterParser.getNodeType(child);
                log(3, "Processing child ", i, " of type: ", nodeType);
                
                try {
                    if (nodeType == "module_def") {
                        // module_def contains the module declaration + all file declarations
                        // Parse contents recursively
                        auto moduleDeclsResult = parseModuleDef(child);
                        declarations ~= moduleDeclsResult;
                    } else if (nodeType == "module_declaration") {
                        // Standalone module declaration (shouldn't happen at root, but handle it)
                        auto modDecl = parseModuleDeclaration(child);
                        if (modDecl !is null) {
                            declarations ~= modDecl;
                            log(2, "Parsed module declaration: ", modDecl.fullyQualifiedName());
                        }
                    } else if (nodeType == "function_declaration") {
                        auto decl = parseFunctionDeclaration(child);
                        declarations ~= decl;
                        log(3, "Successfully parsed function declaration: ", decl.name);
                    } else if (nodeType == "import_declaration") {
                        auto importDecl = parseImportDeclaration(child);
                        if (importDecl !is null) {
                            declarations ~= importDecl;
                        }
                        // Note: magic modules like __ctfe_runtime return null
                    } else if (nodeType == "class_declaration") {
                        declarations ~= parseClassDeclaration(child);
                    } else if (nodeType == "struct_declaration") {
                        declarations ~= parseStructDeclaration(child);
                    } else if (nodeType == "interface_declaration") {
                        declarations ~= parseInterfaceDeclaration(child);
                    } else if (nodeType == "variable_declaration") {
                        declarations ~= parseVariableDeclaration(child);
                    } else if (nodeType == "enum_declaration") {
                        declarations ~= parseEnumDeclaration(child);
                    } else if (nodeType == "manifest_constant") {
                        declarations ~= parseManifestConstant(child);
                    } else if (nodeType == "mixin_declaration") {
                        declarations ~= parseMixinDeclaration(child);
                    } else if (nodeType == "conditional_declaration") {
                        declarations ~= parseConditionalDeclaration(child);
                    } else if (nodeType == "static_assert") {
                        declarations ~= parseStaticAssert(child);
                    } else if (nodeType != "comment" && nodeType.length > 0) {
                        log(2, "Warning: Skipping unknown top-level node: ", nodeType);
                    }
                } catch (ParseError e) {
                    log(2, "Parse error in ", nodeType, ": ", e.msg);
                    // Continue parsing other declarations
                } catch (Exception e) {
                    log(2, "Unexpected error in ", nodeType, ": ", e.msg);
                    // Continue parsing other declarations
                }
            }
            
            return declarations;
        } catch (Exception e) {
            log(2, "Exception in parseSourceFileNode: ", e.msg);
            throw e;
        }
    }
    
    /**
     * Convert function declaration node
     * Returns either FunctionDecl or ImportedFunctionDecl depending on linkage
     */
    Declaration parseFunctionDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        // Parse function declaration by examining children in order:
        // - linkage_attribute (optional, for extern(WASM, "module"))
        // - type (return type)
        // - identifier (function name) 
        // - parameters
        // - function_body
        
        TSNode linkageNode, returnTypeNode, nameNode, parametersNode, bodyNode;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            
            if (nodeType == "linkage_attribute") {
                linkageNode = child;
            } else if (nodeType == "type" && !TreeSitterParser.isValid(returnTypeNode)) {
                returnTypeNode = child;
            } else if (nodeType == "identifier" && !TreeSitterParser.isValid(nameNode)) {
                nameNode = child;
            } else if (nodeType == "parameters") {
                parametersNode = child;
            } else if (nodeType == "function_body") {
                bodyNode = child;
            }
        }
        
        if (!TreeSitterParser.isValid(nameNode)) {
            throw new ParseError("Function declaration missing name", loc);
        }
        
        string name = TreeSitterParser.getNodeText(nameNode, sourceText);
        Type returnType = TreeSitterParser.isValid(returnTypeNode) ? 
            parseType(returnTypeNode) : 
            new BasicType(loc, BasicType.Kind.Void);
        
        Parameter[] parameters;
        if (TreeSitterParser.isValid(parametersNode)) {
            parameters = parseParameterList(parametersNode);
        }
        
        // Check for WASM import linkage
        if (TreeSitterParser.isValid(linkageNode)) {
            string moduleName = parseWasmLinkage(linkageNode);
            if (moduleName !is null) {
                // This is a WASM import declaration
                log(3, "Parsed WASM import: ", moduleName, ".", name);
                return new ImportedFunctionDecl(loc, name, returnType, parameters, moduleName);
            }
        }
        
        // Regular function - parse body
        Statement body_;
        if (TreeSitterParser.isValid(bodyNode)) {
            body_ = parseFunctionBody(bodyNode);
        } else {
            // Abstract function or declaration
            body_ = null;
        }
        
        // TODO: Parse attributes from the tree-sitter node
        string[] attributes;
        
        return new FunctionDecl(loc, name, returnType, parameters, body_, attributes);
    }
    
    /**
     * Parse a linkage_attribute and return the WASM module name if it's a WASM linkage.
     * Returns null if it's not a WASM linkage (e.g., extern(C)).
     */
    private string parseWasmLinkage(TSNode linkageNode) {
        // Structure: linkage_attribute -> extern, "(", "WASM", ",", string_literal, ")"
        // We need to find the string_literal child and extract its content
        
        bool hasWasm = false;
        string moduleName = null;
        
        uint childCount = TreeSitterParser.getChildCount(linkageNode);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(linkageNode, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            string text = TreeSitterParser.getNodeText(child, sourceText);
            
            if (text == "WASM") {
                hasWasm = true;
            } else if (nodeType == "string_literal" && hasWasm) {
                // Extract module name from string literal (remove quotes)
                moduleName = extractStringLiteral(child);
            }
        }
        
        return hasWasm ? moduleName : null;
    }
    
    /**
     * Extract the string content from a string_literal node (handles quoted_string child)
     */
    private string extractStringLiteral(TSNode stringLitNode) {
        // String literal structure: string_literal -> quoted_string
        // The text includes quotes, so we need to strip them
        string text = TreeSitterParser.getNodeText(stringLitNode, sourceText);
        
        // Remove surrounding quotes
        if (text.length >= 2 && text[0] == '"' && text[$-1] == '"') {
            return text[1..$-1];
        }
        return text;
    }
    
    /**
     * List of magic modules that are provided by the compiler.
     * These don't need actual source files.
     */
    private static immutable string[] MAGIC_MODULES = [
        "__ctfe_runtime",
    ];
    
    /**
     * Parse module_def node, which contains:
     *   - module_declaration (the module statement)
     *   - All declarations in the module
     * 
     * Returns array with ModuleDecl first, then all other declarations.
     */
    Declaration[] parseModuleDef(TSNode node) {
        Declaration[] result;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            log(3, "module_def child ", i, ": type=", childType);
            
            if (childType == "module_declaration") {
                auto modDecl = parseModuleDeclaration(child);
                if (modDecl !is null) {
                    result ~= modDecl;
                    log(2, "Parsed module declaration: ", modDecl.fullyQualifiedName());
                }
            } else if (childType == "function_declaration") {
                auto decl = parseFunctionDeclaration(child);
                result ~= decl;
                log(3, "Parsed function in module: ", decl.name);
            } else if (childType == "struct_declaration") {
                result ~= parseStructDeclaration(child);
            } else if (childType == "class_declaration") {
                result ~= parseClassDeclaration(child);
            } else if (childType == "interface_declaration") {
                result ~= parseInterfaceDeclaration(child);
            } else if (childType == "variable_declaration") {
                result ~= parseVariableDeclaration(child);
            } else if (childType == "enum_declaration") {
                result ~= parseEnumDeclaration(child);
            } else if (childType == "manifest_constant") {
                result ~= parseManifestConstant(child);
            } else if (childType == "static_assert") {
                result ~= parseStaticAssert(child);
            } else if (childType == "import_declaration") {
                auto importDecl = parseImportDeclaration(child);
                if (importDecl !is null) {
                    result ~= importDecl;
                }
            } else if (childType == "mixin_declaration") {
                result ~= parseMixinDeclaration(child);
            } else if (childType == "conditional_declaration") {
                result ~= parseConditionalDeclaration(child);
            } else if (childType != "comment" && childType != "module" && 
                       childType != ";" && childType.length > 0) {
                log(2, "Warning: Skipping unknown node in module_def: ", childType);
            }
        }
        
        return result;
    }
    
    /**
     * Parse module declaration: module foo.bar.baz;
     * 
     * Tree-sitter structure:
     *   module_declaration
     *     └─ module (keyword)
     *     └─ module_fqn (the path)
     *         └─ identifier (each component)
     *     └─ ; (semicolon)
     */
    ModuleDecl parseModuleDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        string[] modulePath;
        
        string nodeType = TreeSitterParser.getNodeType(node);
        log(3, "Parsing module declaration, node type: ", nodeType);
        
        // If this is module_def, we need to find module_declaration inside
        if (nodeType == "module_def") {
            uint childCount = TreeSitterParser.getChildCount(node);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                string childType = TreeSitterParser.getNodeType(child);
                if (childType == "module_declaration") {
                    return parseModuleDeclaration(child);  // Recurse into actual declaration
                }
            }
            log(2, "Warning: module_def has no module_declaration child");
            return null;
        }
        
        // Parse module_declaration node
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            string text = TreeSitterParser.getNodeText(child, sourceText);
            
            log(3, "  Module decl child ", i, ": type=", childType, ", text='", text, "'");
            
            if (childType == "module_fqn") {
                // Extract path components from module_fqn
                modulePath = parseModuleFQN(child);
            } else if (childType == "identifier" && modulePath.length == 0) {
                // Single identifier module name
                modulePath = [text];
            }
        }
        
        if (modulePath.length == 0) {
            log(2, "Warning: Could not extract module path from declaration");
            return null;
        }
        
        log(2, "Parsed module: ", modulePath);
        return new ModuleDecl(loc, modulePath);
    }
    
    /**
     * Parse module_fqn node to extract path components.
     * module_fqn contains identifiers separated by dots.
     */
    private string[] parseModuleFQN(TSNode node) {
        string[] path;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            string text = TreeSitterParser.getNodeText(child, sourceText);
            
            if (childType == "identifier") {
                path ~= text;
            } else if (childType == "module_fqn") {
                // Nested module_fqn (recursive structure)
                path ~= parseModuleFQN(child);
            }
        }
        
        // If no children extracted, try getting the whole text and splitting
        if (path.length == 0) {
            string fullText = TreeSitterParser.getNodeText(node, sourceText);
            import std.algorithm : splitter;
            import std.array : array;
            path = fullText.splitter(".").array;
        }
        
        return path;
    }
    
    /**
     * Parse import declaration: import modulename;
     * Returns null for magic modules (they're handled specially in CTFE).
     */
    Declaration parseImportDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        // Extract module name from import declaration
        // Structure varies by tree-sitter D grammar:
        // - Could be: import_declaration -> import, module_fqn, ;
        // - Or: import_declaration -> import, single_import, ;
        // - Or: import_declaration containing just the module name
        string moduleName;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            string text = TreeSitterParser.getNodeText(child, sourceText);
            
            // Try various possible node types for module name
            if (nodeType == "module_fqn" || nodeType == "identifier" || 
                nodeType == "single_import" || nodeType == "module_name" ||
                nodeType == "imported" || nodeType == "type") {
                // For wrapper nodes, might need to go deeper
                if (nodeType == "single_import" || nodeType == "module_name" || nodeType == "imported") {
                    moduleName = extractModuleName(child);
                } else {
                    moduleName = text;
                }
                if (moduleName.length > 0 && moduleName != "import") {
                    break;
                }
            }
        }
        
        if (moduleName.length == 0) {
            throw new ParseError("Import declaration missing module name", loc);
        }
        
        // Check if this is a magic module
        foreach (magic; MAGIC_MODULES) {
            if (moduleName == magic) {
                return null;  // Magic modules don't create declarations
            }
        }
        
        // For regular imports, we'd need to load and parse the module
        // For now, just warn and return null
        throw new ParseError(
            "Cannot import module '" ~ moduleName ~ "': module imports not yet implemented",
            loc,
            "only magic modules like __ctfe_runtime are supported"
        );
    }
    
    /**
     * Extract module name from a single_import or module_name node by walking children.
     */
    private string extractModuleName(TSNode node) {
        // First try to get text directly
        string text = TreeSitterParser.getNodeText(node, sourceText);
        
        // Look for identifier children
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            
            if (nodeType == "identifier" || nodeType == "module_fqn") {
                return TreeSitterParser.getNodeText(child, sourceText);
            }
        }
        
        // Return the node text if no identifier found
        return text;
    }
    
    /**
     * Parse function parameters
     */
    Parameter[] parseParameterList(TSNode parametersNode) {
        Parameter[] parameters;
        
        uint childCount = TreeSitterParser.getChildCount(parametersNode);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(parametersNode, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            
            if (nodeType == "parameter") {
                parameters ~= parseParameter(child);
            }
        }
        
        return parameters;
    }
    
    /**
     * Parse a single parameter
     */
    Parameter parseParameter(TSNode parameterNode) {
        // Parameter structure: type identifier [default_value]
        TSNode typeNode, nameNode, defaultNode;
        
        uint childCount = TreeSitterParser.getChildCount(parameterNode);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(parameterNode, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            
            if (nodeType == "type" && !TreeSitterParser.isValid(typeNode)) {
                typeNode = child;
            } else if (nodeType == "identifier" && !TreeSitterParser.isValid(nameNode)) {
                nameNode = child;
            } else if (nodeType == "default_value") {
                defaultNode = child;
            }
        }
        
        if (!TreeSitterParser.isValid(typeNode) || !TreeSitterParser.isValid(nameNode)) {
            throw new ParseError("Parameter missing type or name", makeSourceLocation(parameterNode));
        }
        
        Type paramType = parseType(typeNode);
        string paramName = TreeSitterParser.getNodeText(nameNode, sourceText);
        Expression defaultValue = TreeSitterParser.isValid(defaultNode) ? parseExpression(defaultNode) : null;
        
        return Parameter(paramType, paramName, defaultValue);
    }
    
    /**
     * Parse function body
     */
    Statement parseFunctionBody(TSNode bodyNode) {
        uint childCount = TreeSitterParser.getChildCount(bodyNode);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(bodyNode, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            
            if (nodeType == "block_statement") {
                return parseBlockStatement(child);
            }
        }
        
        throw new ParseError("Function body missing block statement", makeSourceLocation(bodyNode));
    }
    
    /**
     * Parse block statement
     */
    CompoundStatement parseBlockStatement(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        Statement[] statements;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            
            // Skip braces and parse actual statements
            if (nodeType != "{" && nodeType != "}") {
                // NOTE: Previously had try/catch here that silently dropped statements on parse errors.
                // Removed because it was hiding bugs (e.g., cast expressions failing to parse).
                // If error recovery is needed, it should be at a higher level.
                auto stmt = parseStatement(child);
                if (stmt !is null) {  // Skip null statements (e.g., comments)
                    statements ~= stmt;
                }
            }
        }
        
        return new CompoundStatement(loc, statements);
    }
    
    /**
     * Parse class declaration
     */
    ClassDecl parseClassDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        string name;
        Type baseClass = null;
        Type[] interfaces;
        Declaration[] members;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "identifier") {
                name = TreeSitterParser.getNodeText(child, sourceText);
            } else if (childType == "aggregate_body") {
                members = parseAggregateBody(child);
            } else if (childType == "base_class_list" || childType == "super_class" || childType == "base_class") {
                // Parse inheritance - accumulate all base types
                auto inheritTypes = parseBaseClassList(child);
                foreach (t; inheritTypes) {
                    if (baseClass is null) {
                        // First type goes to baseClass (may be moved to interfaces later by type checker)
                        baseClass = t;
                    } else {
                        interfaces ~= t;
                    }
                }
            }
        }
        
        if (name.length == 0) {
            throw new ParseError("Class declaration missing name", loc);
        }
        
        auto classDecl = new ClassDecl(loc, name, baseClass, interfaces, members);
        
        // Mark FunctionDecl members as methods and extract constructor/destructor
        foreach (member; members) {
            if (auto funcDecl = cast(FunctionDecl)member) {
                funcDecl.isMethod = true;
                funcDecl.parent = classDecl;
                
                // Check for constructor (this)
                if (funcDecl.name == "this" || funcDecl.isConstructor) {
                    classDecl.constructor = funcDecl;
                }
                
                // Check for destructor (~this)
                if (funcDecl.isDestructor) {
                    classDecl.destructor = funcDecl;
                }
            }
        }
        
        return classDecl;
    }
    
    /**
     * Parse base class list for inheritance
     */
    private Type[] parseBaseClassList(TSNode node) {
        Type[] types;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "identifier" || childType == "type" || childType == "type_identifier") {
                string typeName = TreeSitterParser.getNodeText(child, sourceText);
                auto loc = makeSourceLocation(child);
                types ~= new UserType(loc, typeName);
            } else if (childType == "qualified_identifier") {
                string typeName = TreeSitterParser.getNodeText(child, sourceText);
                auto loc = makeSourceLocation(child);
                types ~= new UserType(loc, typeName);
            }
        }
        
        return types;
    }
    
    /**
     * Parse struct declaration
     */
    StructDecl parseStructDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        string name;
        Declaration[] members;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "identifier") {
                name = TreeSitterParser.getNodeText(child, sourceText);
            } else if (childType == "aggregate_body") {
                members = parseAggregateBody(child);
            }
        }
        
        if (name.length == 0) {
            throw new ParseError("Struct declaration missing name", loc);
        }
        
        auto structDecl = new StructDecl(loc, name, members);
        
        // Mark any FunctionDecl members as methods and set their parent
        // Extract destructor if present
        foreach (member; members) {
            if (auto funcDecl = cast(FunctionDecl)member) {
                funcDecl.isMethod = true;
                funcDecl.parent = structDecl;
                
                // Check if this is a destructor
                if (funcDecl.isDestructor) {
                    structDecl.destructor = funcDecl;
                }
            }
        }
        
        return structDecl;
    }
    
    /**
     * Parse aggregate body (struct/class body with member declarations)
     */
    Declaration[] parseAggregateBody(TSNode node) {
        Declaration[] members;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "variable_declaration" || childType == "field_declaration") {
                members ~= parseVariableDeclaration(child);
            } else if (childType == "function_declaration") {
                members ~= parseFunctionDeclaration(child);
            } else if (childType == "destructor") {
                members ~= parseDestructor(child);
            } else if (childType == "constructor") {
                members ~= parseConstructor(child);
            }
            // Skip braces, semicolons, etc.
        }
        
        return members;
    }
    
    /**
     * Parse constructor (this(...) { ... })
     */
    FunctionDecl parseConstructor(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        // Parse parameters
        Parameter[] parameters;
        TSNode paramsNode = TreeSitterParser.getChildByFieldName(node, "parameters");
        if (!TreeSitterParser.isValid(paramsNode)) {
            // Try finding by type
            uint childCount = TreeSitterParser.getChildCount(node);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                if (TreeSitterParser.getNodeType(child) == "parameters") {
                    paramsNode = child;
                    break;
                }
            }
        }
        
        if (TreeSitterParser.isValid(paramsNode)) {
            parameters = parseParameterList(paramsNode);
        }
        
        // Find the function body
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "function_body");
        if (!TreeSitterParser.isValid(bodyNode)) {
            uint childCount = TreeSitterParser.getChildCount(node);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                if (TreeSitterParser.getNodeType(child) == "function_body") {
                    bodyNode = child;
                    break;
                }
            }
        }
        
        Statement body_ = null;
        if (TreeSitterParser.isValid(bodyNode)) {
            body_ = parseFunctionBody(bodyNode);
        }
        
        // Create constructor as a special function named "this"
        auto ctor = new FunctionDecl(
            loc,
            "this",
            new BasicType(loc, BasicType.Kind.Void),  // Constructors return void
            parameters,
            body_,
            [],   // No attributes
            false  // Not public
        );
        ctor.isConstructor = true;
        
        return ctor;
    }
    
    /**
     * Parse destructor (~this() { ... })
     */
    FunctionDecl parseDestructor(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        // Find the function body
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "function_body");
        if (!TreeSitterParser.isValid(bodyNode)) {
            // Try getting by type instead
            uint childCount = TreeSitterParser.getChildCount(node);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                string childType = TreeSitterParser.getNodeType(child);
                if (childType == "function_body") {
                    bodyNode = child;
                    break;
                }
            }
        }
        
        Statement body_ = null;
        if (TreeSitterParser.isValid(bodyNode)) {
            body_ = parseFunctionBody(bodyNode);
        }
        
        // Create destructor as a special function named "~this"
        auto dtor = new FunctionDecl(
            loc,
            "~this",
            new BasicType(loc, BasicType.Kind.Void),  // Destructors return void
            [],  // No parameters
            body_,
            [],   // No attributes
            false  // Not public
        );
        dtor.isDestructor = true;
        
        return dtor;
    }
    
    /**
     * Parse interface declaration
     */
    InterfaceDecl parseInterfaceDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        string name;
        Type[] parentInterfaces;
        FunctionDecl[] methods;
        
        // Parse children to find name and body (similar to class parsing)
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "identifier") {
                name = TreeSitterParser.getNodeText(child, sourceText);
            } else if (childType == "aggregate_body") {
                // Parse interface methods
                methods = parseInterfaceMethods(child);
            }
        }
        
        if (name.length == 0) {
            throw new ParseError("Interface declaration missing name", loc);
        }
        
        return new InterfaceDecl(loc, name, parentInterfaces, methods);
    }
    
    /**
     * Parse interface method declarations (signatures only, no bodies)
     */
    private FunctionDecl[] parseInterfaceMethods(TSNode body) {
        FunctionDecl[] methods;
        
        uint childCount = TreeSitterParser.getChildCount(body);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(body, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "function_declaration" || childType == "function_signature") {
                auto method = parseInterfaceMethod(child);
                if (method) {
                    method.isMethod = true;
                    methods ~= method;
                }
            }
        }
        
        return methods;
    }
    
    /**
     * Parse interface method (signature without body)
     */
    private FunctionDecl parseInterfaceMethod(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        Type returnType = null;
        string name;
        Parameter[] parameters;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "type" || childType == "basic_type" || childType == "builtin_type") {
                returnType = parseType(child);
            } else if (childType == "identifier") {
                name = TreeSitterParser.getNodeText(child, sourceText);
            } else if (childType == "parameters") {
                parameters = parseParameterList(child);
            }
        }
        
        if (name.length == 0) {
            return null;
        }
        
        if (returnType is null) {
            returnType = new BasicType(loc, BasicType.Kind.Void);
        }
        
        auto decl = new FunctionDecl(loc, name, returnType, parameters, null);
        return decl;
    }
    
    /**
     * Parse variable declaration
     * 
     * Tree-sitter structure:
     *   variable_declaration
     *     type (contains int/float/etc)
     *     declarator (contains identifier and optional initializer)
     */
    VariableDecl parseVariableDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        // Try field-based access first
        TSNode typeNode = TreeSitterParser.getChildByFieldName(node, "type");
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        TSNode initNode = TreeSitterParser.getChildByFieldName(node, "initializer");
        
        // If field-based access fails, iterate children
        if (!TreeSitterParser.isValid(typeNode)) {
            TSNode declaratorNode;
            uint childCount = TreeSitterParser.getChildCount(node);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                string childType = TreeSitterParser.getNodeType(child);
                
                if (childType == "type") {
                    typeNode = child;
                } else if (childType == "declarator") {
                    declaratorNode = child;
                }
            }
            
            // Parse name and initializer from declarator
            if (TreeSitterParser.isValid(declaratorNode)) {
                uint declChildCount = TreeSitterParser.getChildCount(declaratorNode);
                for (uint i = 0; i < declChildCount; i++) {
                    TSNode child = TreeSitterParser.getChild(declaratorNode, i);
                    string childType = TreeSitterParser.getNodeType(child);
                    
                    if (childType == "identifier" && !TreeSitterParser.isValid(nameNode)) {
                        nameNode = child;
                    } else if (childType != "=" && childType != "identifier" && 
                               TreeSitterParser.isValid(nameNode) && !TreeSitterParser.isValid(initNode)) {
                        // This should be the initializer expression
                        initNode = child;
                    }
                }
            }
        }
        
        if (!TreeSitterParser.isValid(typeNode) || !TreeSitterParser.isValid(nameNode)) {
            throw new ParseError("Variable declaration missing type or name", loc);
        }
        
        Type varType = parseType(typeNode);
        string name = TreeSitterParser.getNodeText(nameNode, sourceText);
        Expression initializer = TreeSitterParser.isValid(initNode) ? parseExpression(initNode) : null;
        
        return new VariableDecl(loc, name, varType, initializer);
    }
    
    /**
     * Parse enum declaration
     */
    /**
     * Parse manifest constant: enum NAME = expression;
     */
    ManifestConstantDecl parseManifestConstant(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        // Find the manifest_declarator child
        TSNode declarator;
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "manifest_declarator") {
                declarator = child;
                break;
            }
        }
        
        if (!TreeSitterParser.isValid(declarator)) {
            throw new ParseError("Manifest constant missing declarator", loc);
        }
        
        // Parse the declarator: NAME = expression
        TSNode nameNode;
        TSNode initNode;
        
        uint declChildCount = TreeSitterParser.getChildCount(declarator);
        for (uint i = 0; i < declChildCount; i++) {
            TSNode child = TreeSitterParser.getChild(declarator, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "identifier") {
                nameNode = child;
            } else if (childType != "=" && childType.length > 0) {
                // This should be the expression
                initNode = child;
            }
        }
        
        if (!TreeSitterParser.isValid(nameNode)) {
            throw new ParseError("Manifest constant missing name", loc);
        }
        
        string name = TreeSitterParser.getNodeText(nameNode, sourceText);
        
        Expression initializer = null;
        if (TreeSitterParser.isValid(initNode)) {
            initializer = parseExpression(initNode);
        } else {
            throw new ParseError("Manifest constant '" ~ name ~ "' missing initializer", loc);
        }
        
        log(3, "Parsed manifest constant: ", name, " = ", initializer.toString());
        return new ManifestConstantDecl(loc, name, initializer);
    }
    
    EnumDecl parseEnumDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        if (!TreeSitterParser.isValid(nameNode)) {
            throw new ParseError("Enum declaration missing name", loc);
        }
        
        string name = TreeSitterParser.getNodeText(nameNode, sourceText);
        
        // TODO: Parse base type and enum members
        Type baseType = new BasicType(loc, BasicType.Kind.Int32);
        EnumMember[] members;
        
        return new EnumDecl(loc, name, baseType, members);
    }
    
    /**
     * Parse mixin declaration: mixin(expression);
     * 
     * Tree-sitter structure:
     *   mixin_declaration
     *     mixin_expression
     *       mixin
     *       expression (contains the identifier or string expr)
     */
    MixinDecl parseMixinDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        // Find the mixin_expression child
        TSNode mixinExprNode;
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "mixin_expression") {
                mixinExprNode = child;
                break;
            }
        }
        
        if (!TreeSitterParser.isValid(mixinExprNode)) {
            throw new ParseError("Mixin declaration missing mixin_expression", loc);
        }
        
        // Find the expression inside mixin_expression
        // Structure: mixin_expression has children: mixin, (, expression, )
        TSNode exprNode;
        uint mixinChildCount = TreeSitterParser.getChildCount(mixinExprNode);
        for (uint i = 0; i < mixinChildCount; i++) {
            TSNode child = TreeSitterParser.getChild(mixinExprNode, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "expression" || childType == "identifier" || 
                childType == "string_literal" || childType.endsWith("_expression")) {
                exprNode = child;
                break;
            }
        }
        
        if (!TreeSitterParser.isValid(exprNode)) {
            throw new ParseError("Mixin expression missing argument", loc);
        }
        
        // Parse the expression
        Expression mixinArg = parseExpression(exprNode);
        
        log(3, "Parsed mixin declaration: mixin(", mixinArg.toString(), ")");
        
        return new MixinDecl(loc, mixinArg);
    }
    
    /**
     * Parse conditional declaration: static if (condition) { ... } else { ... }
     * 
     * Tree-sitter structure:
     *   conditional_declaration
     *     condition (contains static_if_condition, version_condition, or debug_condition)
     *       static_if_condition
     *         static
     *         if
     *         (
     *         expression
     *         )
     *     { or _declaration
     *     _declarations...
     *     } (if braced)
     *     else (optional)
     *     { or _declaration
     *     _declarations...
     *     } (if braced)
     */
    StaticIfDecl parseConditionalDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        // Debug: print the tree structure
        log(3, "Parsing conditional_declaration with ", TreeSitterParser.getChildCount(node), " children:");
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            log(3, "  Child ", i, ": ", childType);
        }
        
        // Find the condition node (first child that is 'condition')
        TSNode conditionNode;
        Expression conditionExpr;
        Declaration[] thenDecls;
        Declaration[] elseDecls;
        
        bool foundElse = false;
        bool inThenBranch = false;
        
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "condition") {
                // Parse the condition - find static_if_condition inside
                conditionExpr = parseCondition(child);
                inThenBranch = true;
            } else if (childType == "else") {
                foundElse = true;
                inThenBranch = false;
            } else if (childType == "{" || childType == "}") {
                // Skip braces
                continue;
            } else if (childType == ":") {
                // Skip colons (used in some forms)
                continue;
            } else if (inThenBranch && !foundElse) {
                // This is a declaration in the then branch
                auto decls = parseDeclarationNode(child);
                thenDecls ~= decls;
            } else if (foundElse) {
                // This is a declaration in the else branch
                auto decls = parseDeclarationNode(child);
                elseDecls ~= decls;
            }
        }
        
        if (conditionExpr is null) {
            throw new ParseError("Conditional declaration missing condition", loc);
        }
        
        log(3, "Parsed static if: condition=", conditionExpr.toString(), 
                ", then=", thenDecls.length, " decls, else=", elseDecls.length, " decls");
        
        return new StaticIfDecl(loc, conditionExpr, thenDecls, elseDecls);
    }
    
    /**
     * Parse static_assert declaration
     * Structure: static_assert > assert_expression > assert_arguments > expression(s)
     */
    StaticAssertDecl parseStaticAssert(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        Expression conditionExpr;
        Expression messageExpr;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "assert_expression") {
                // Dive into assert_expression to find assert_arguments
                uint assertChildCount = TreeSitterParser.getChildCount(child);
                for (uint j = 0; j < assertChildCount; j++) {
                    TSNode assertChild = TreeSitterParser.getChild(child, j);
                    string assertChildType = TreeSitterParser.getNodeType(assertChild);
                    
                    if (assertChildType == "assert_arguments") {
                        // Parse expressions from assert_arguments
                        uint argCount = TreeSitterParser.getChildCount(assertChild);
                        int exprIndex = 0;
                        for (uint k = 0; k < argCount; k++) {
                            TSNode argChild = TreeSitterParser.getChild(assertChild, k);
                            string argChildType = TreeSitterParser.getNodeType(argChild);
                            
                            // Skip punctuation
                            if (argChildType == "(" || argChildType == ")" || argChildType == ",") {
                                continue;
                            }
                            
                            if (exprIndex == 0) {
                                conditionExpr = parseExpression(argChild);
                                exprIndex++;
                            } else if (exprIndex == 1) {
                                messageExpr = parseExpression(argChild);
                                exprIndex++;
                            }
                        }
                    }
                }
            }
        }
        
        if (conditionExpr is null) {
            throw new ParseError("static assert missing condition", loc);
        }
        
        log(3, "Parsed static assert: condition=", conditionExpr.toString(),
            messageExpr !is null ? ", message=" ~ messageExpr.toString() : "");
        
        return new StaticAssertDecl(loc, conditionExpr, messageExpr);
    }
    
    /**
     * Parse the condition from a condition node (static if, version, or debug)
     */
    private Expression parseCondition(TSNode conditionNode) {
        uint childCount = TreeSitterParser.getChildCount(conditionNode);
        
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(conditionNode, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "static_if_condition") {
                return parseStaticIfCondition(child);
            }
            // TODO: Handle version_condition and debug_condition
        }
        
        throw new ParseError("Unsupported condition type in conditional declaration", 
                           makeSourceLocation(conditionNode));
    }
    
    /**
     * Parse static_if_condition: static if ( expression )
     */
    private Expression parseStaticIfCondition(TSNode node) {
        uint childCount = TreeSitterParser.getChildCount(node);
        
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            // Skip 'static', 'if', '(', ')'
            if (childType != "static" && childType != "if" && 
                childType != "(" && childType != ")") {
                // This should be the expression
                return parseExpression(child);
            }
        }
        
        throw new ParseError("static if condition missing expression", makeSourceLocation(node));
    }
    
    /**
     * Parse a single declaration node, returning an array (some nodes expand to multiple decls)
     */
    private Declaration[] parseDeclarationNode(TSNode node) {
        string nodeType = TreeSitterParser.getNodeType(node);
        SourceLocation loc = makeSourceLocation(node);
        
        log(3, "  Parsing declaration node of type: ", nodeType);
        
        if (nodeType == "function_declaration") {
            return [parseFunctionDeclaration(node)];
        } else if (nodeType == "class_declaration") {
            return [parseClassDeclaration(node)];
        } else if (nodeType == "struct_declaration") {
            return [parseStructDeclaration(node)];
        } else if (nodeType == "interface_declaration") {
            return [parseInterfaceDeclaration(node)];
        } else if (nodeType == "variable_declaration") {
            return [parseVariableDeclaration(node)];
        } else if (nodeType == "enum_declaration") {
            return [parseEnumDeclaration(node)];
        } else if (nodeType == "manifest_constant") {
            return [parseManifestConstant(node)];
        } else if (nodeType == "mixin_declaration") {
            return [parseMixinDeclaration(node)];
        } else if (nodeType == "conditional_declaration") {
            return [parseConditionalDeclaration(node)];
        } else if (nodeType == "static_assert") {
            return [parseStaticAssert(node)];
        } else if (nodeType == "declaration_or_statement") {
            // Some grammar variants use this wrapper
            uint childCount = TreeSitterParser.getChildCount(node);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                auto decls = parseDeclarationNode(child);
                if (decls.length > 0) return decls;
            }
        }
        
        // Unknown node type - return empty
        log(2, "  Warning: Unknown declaration node type: ", nodeType);
        return [];
    }
    
    /**
     * Parse type from tree-sitter node
     */
    Type parseType(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        string nodeType = TreeSitterParser.getNodeType(node);
        
        // Handle different type node structures
        if (nodeType == "type") {
            uint childCount = TreeSitterParser.getChildCount(node);
            
            // Check for array type pattern: baseType '[' [size] ']'
            // Tree-sitter gives us children like: int, [, ] (dynamic) or int, [, expression, ] (static)
            if (childCount >= 3) {
                TSNode lastChild = TreeSitterParser.getChild(node, childCount - 1);
                if (TreeSitterParser.getNodeType(lastChild) == "]") {
                    // Find the '[' and check for size expression between
                    Expression sizeExpr = null;
                    TSNode baseTypeNode;
                    bool foundBracket = false;
                    
                    for (uint i = 0; i < childCount; i++) {
                        TSNode child = TreeSitterParser.getChild(node, i);
                        string childType = TreeSitterParser.getNodeType(child);
                        
                        if (childType == "[") {
                            foundBracket = true;
                        } else if (childType == "]") {
                            // End of array syntax
                        } else if (foundBracket && sizeExpr is null && childType != "]") {
                            // This is the size expression (between [ and ])
                            sizeExpr = parseExpression(child);
                        } else if (!foundBracket && !TreeSitterParser.isValid(baseTypeNode)) {
                            // First non-bracket element before [ is the base type
                            baseTypeNode = child;
                        }
                    }
                    
                    if (TreeSitterParser.isValid(baseTypeNode)) {
                        Type baseType = parseType(baseTypeNode);
                        return new ArrayType(loc, baseType, sizeExpr);
                    }
                }
            }
            
            // Look for the actual type inside the type node, skipping type_ctor
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                string childType = TreeSitterParser.getNodeType(child);
                // Skip type constructors like 'immutable', 'const', 'shared'
                if (childType != "type_ctor") {
                    return parseType(child);
                }
            }
            // If only type_ctor found, fall through to default
        }
        
        switch (nodeType) {
            case "int":
                return new BasicType(loc, BasicType.Kind.Int32);
            case "void":
                return new BasicType(loc, BasicType.Kind.Void);
            case "bool":
                return new BasicType(loc, BasicType.Kind.Bool);
            case "byte":
                return new BasicType(loc, BasicType.Kind.Int8);
            case "short":
                return new BasicType(loc, BasicType.Kind.Int16);
            case "long":
                return new BasicType(loc, BasicType.Kind.Int64);
            case "ubyte":
                return new BasicType(loc, BasicType.Kind.UInt8);
            case "ushort":
                return new BasicType(loc, BasicType.Kind.UInt16);
            case "uint":
                return new BasicType(loc, BasicType.Kind.UInt32);
            case "ulong":
                return new BasicType(loc, BasicType.Kind.UInt64);
            case "float":
                return new BasicType(loc, BasicType.Kind.Float32);
            case "double":
                return new BasicType(loc, BasicType.Kind.Float64);
            case "char":
                return new BasicType(loc, BasicType.Kind.Char);
            case "string":
                // string is an alias for immutable(ubyte)[] — desugar at parse time
                return new ArrayType(loc, new BasicType(loc, BasicType.Kind.UInt8));
            case "array_type":
                return parseArrayType(node, loc);
            case "pointer_type":
                return parsePointerType(node, loc);
            case "identifier":
                return new UserType(loc, TreeSitterParser.getNodeText(node, sourceText));
            default:
                // Try to parse the text directly as a basic type
                return parseBasicTypeByText(TreeSitterParser.getNodeText(node, sourceText), loc);
        }
    }
    
    /**
     * Parse basic type by text content
     */
    BasicType parseBasicTypeByText(string typeName, SourceLocation loc) {
        switch (typeName) {
            case "void": return new BasicType(loc, BasicType.Kind.Void);
            case "bool": return new BasicType(loc, BasicType.Kind.Bool);
            case "byte": return new BasicType(loc, BasicType.Kind.Int8);
            case "short": return new BasicType(loc, BasicType.Kind.Int16);
            case "int": return new BasicType(loc, BasicType.Kind.Int32);
            case "long": return new BasicType(loc, BasicType.Kind.Int64);
            case "ubyte": return new BasicType(loc, BasicType.Kind.UInt8);
            case "ushort": return new BasicType(loc, BasicType.Kind.UInt16);
            case "uint": return new BasicType(loc, BasicType.Kind.UInt32);
            case "ulong": return new BasicType(loc, BasicType.Kind.UInt64);
            case "float": return new BasicType(loc, BasicType.Kind.Float32);
            case "double": return new BasicType(loc, BasicType.Kind.Float64);
            case "char": return new BasicType(loc, BasicType.Kind.Char);
            default:
                return new BasicType(loc, BasicType.Kind.Int32);  // Default to int
        }
    }
    
    /**
     * Parse basic type
     */
    BasicType parseBasicType(TSNode node, SourceLocation loc) {
        string typeName = TreeSitterParser.getNodeText(node, sourceText);
        
        switch (typeName) {
            case "void": return new BasicType(loc, BasicType.Kind.Void);
            case "bool": return new BasicType(loc, BasicType.Kind.Bool);
            case "byte": return new BasicType(loc, BasicType.Kind.Int8);
            case "short": return new BasicType(loc, BasicType.Kind.Int16);
            case "int": return new BasicType(loc, BasicType.Kind.Int32);
            case "long": return new BasicType(loc, BasicType.Kind.Int64);
            case "ubyte": return new BasicType(loc, BasicType.Kind.UInt8);
            case "ushort": return new BasicType(loc, BasicType.Kind.UInt16);
            case "uint": return new BasicType(loc, BasicType.Kind.UInt32);
            case "ulong": return new BasicType(loc, BasicType.Kind.UInt64);
            case "float": return new BasicType(loc, BasicType.Kind.Float32);
            case "double": return new BasicType(loc, BasicType.Kind.Float64);
            case "char": return new BasicType(loc, BasicType.Kind.Char);
            default:
                throw new ParseError("Unknown basic type: " ~ typeName, loc);
        }
    }
    
    /**
     * Parse array type
     */
    ArrayType parseArrayType(TSNode node, SourceLocation loc) {
        TSNode elementTypeNode = TreeSitterParser.getChildByFieldName(node, "element_type");
        TSNode sizeNode = TreeSitterParser.getChildByFieldName(node, "size");
        
        if (!TreeSitterParser.isValid(elementTypeNode)) {
            throw new ParseError("Array type missing element type", loc);
        }
        
        Type elementType = parseType(elementTypeNode);
        Expression size = TreeSitterParser.isValid(sizeNode) ? parseExpression(sizeNode) : null;
        
        return new ArrayType(loc, elementType, size);
    }
    
    /**
     * Parse pointer type
     */
    PointerType parsePointerType(TSNode node, SourceLocation loc) {
        TSNode pointeeTypeNode = TreeSitterParser.getChildByFieldName(node, "pointee_type");
        
        if (!TreeSitterParser.isValid(pointeeTypeNode)) {
            throw new ParseError("Pointer type missing pointee type", loc);
        }
        
        Type pointeeType = parseType(pointeeTypeNode);
        return new PointerType(loc, pointeeType);
    }
    
    /**
     * Parse statement from tree-sitter node
     */
    Statement parseStatement(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        string nodeType = TreeSitterParser.getNodeType(node);
        
        // Debug: print node info
        log(3, "Parsing statement: ", nodeType, " with ", TreeSitterParser.getChildCount(node), " children");
        for (uint i = 0; i < TreeSitterParser.getChildCount(node); i++) {
            log(3, "  Child ", i, ": ", TreeSitterParser.getNodeType(TreeSitterParser.getChild(node, i)), 
                    " (field: ", TreeSitterParser.getChildFieldName(node, i), ")");
        }
        
        switch (nodeType) {
            case "block_statement":
                return parseCompoundStatement(node, loc);
            case "scope_statement":
                // scope_statement usually has one child: a block_statement or a simple statement
                if (TreeSitterParser.getChildCount(node) > 0) {
                    return parseStatement(TreeSitterParser.getChild(node, 0));
                }
                throw new ParseError("Empty scope_statement", loc);
            case "if_statement":
                return parseIfStatement(node, loc);
            case "while_statement":
                return parseWhileStatement(node, loc);
            case "for_statement":
                return parseForStatement(node, loc);
            case "return_statement":
                return parseReturnStatement(node, loc);
            case "expression_statement":
                return parseExpressionStatement(node, loc);
            case "variable_declaration":
                return parseVariableDeclarationStatement(node, loc);
            case "mixin_declaration":
                return parseMixinStatement(node, loc);
            case "break_statement":
                return new BreakStatement(loc);
            case "continue_statement":
                return new ContinueStatement(loc);
            case "comment":
                // Skip comments - return null (handled by caller)
                return null;
            default:
                throw new ParseError("Unknown statement node: " ~ nodeType, loc);
        }
    }
    
    /**
     * Parse mixin statement: mixin(expression);
     * Returns a MixinStatement that will be expanded during semantic analysis.
     */
    MixinStatement parseMixinStatement(TSNode node, SourceLocation loc) {
        // Find the mixin_expression child
        TSNode mixinExprNode;
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "mixin_expression") {
                mixinExprNode = child;
                break;
            }
        }
        
        if (!TreeSitterParser.isValid(mixinExprNode)) {
            throw new ParseError("Mixin statement missing mixin_expression", loc);
        }
        
        // Find the expression inside mixin_expression
        TSNode exprNode;
        uint mixinChildCount = TreeSitterParser.getChildCount(mixinExprNode);
        for (uint i = 0; i < mixinChildCount; i++) {
            TSNode child = TreeSitterParser.getChild(mixinExprNode, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "expression" || childType == "identifier" || 
                childType == "string_literal" || childType.endsWith("_expression")) {
                exprNode = child;
                break;
            }
        }
        
        if (!TreeSitterParser.isValid(exprNode)) {
            throw new ParseError("Mixin expression missing argument", loc);
        }
        
        // Parse the expression
        Expression mixinArg = parseExpression(exprNode);
        
        log(3, "Parsed mixin statement: mixin(", mixinArg.toString(), ")");
        
        return new MixinStatement(loc, mixinArg);
    }
    
    /**
     * Parse compound statement
     */
    CompoundStatement parseCompoundStatement(TSNode node, SourceLocation loc) {
        Statement[] statements;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            
            if (nodeType != "{" && nodeType != "}") {
                auto stmt = parseStatement(child);
                if (stmt !is null) {  // Skip null statements (e.g., comments)
                    statements ~= stmt;
                }
            }
        }
        return new CompoundStatement(loc, statements);
    }
    
    /**
     * Parse if statement
     */
    IfStatement parseIfStatement(TSNode node, SourceLocation loc) {
        TSNode conditionNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode thenNode = TreeSitterParser.getChildByFieldName(node, "consequence");
        TSNode elseNode = TreeSitterParser.getChildByFieldName(node, "alternative");
        
        // Fallback for if_condition node
        if (!TreeSitterParser.isValid(conditionNode)) {
            uint childCount = TreeSitterParser.getChildCount(node);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                if (TreeSitterParser.getNodeType(child) == "if_condition") {
                    // if_condition usually has '(' expression ')'
                    uint condChildren = TreeSitterParser.getChildCount(child);
                    for (uint j = 0; j < condChildren; j++) {
                        TSNode condChild = TreeSitterParser.getChild(child, j);
                        if (TreeSitterParser.getNodeType(condChild).endsWith("expression") || 
                            TreeSitterParser.getNodeType(condChild) == "identifier") {
                            conditionNode = condChild;
                            break;
                        }
                    }
                }
                if (TreeSitterParser.getNodeType(child).endsWith("statement") && !TreeSitterParser.isValid(thenNode)) {
                    thenNode = child;
                }
            }
        }
        
        if (!TreeSitterParser.isValid(conditionNode) || !TreeSitterParser.isValid(thenNode)) {
            throw new ParseError("If statement missing condition or body", loc);
        }
        
        Expression condition = parseExpression(conditionNode);
        Statement thenStatement = parseStatement(thenNode);
        Statement elseStatement = TreeSitterParser.isValid(elseNode) ? parseStatement(elseNode) : null;
        
        return new IfStatement(loc, condition, thenStatement, elseStatement);
    }
    
    /**
     * Parse while statement
     */
    WhileStatement parseWhileStatement(TSNode node, SourceLocation loc) {
        // tree-sitter-d uses different field names
        // while_statement children: "while", if_condition, scope_statement (field: body)
        TSNode conditionNode;
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");
        
        // Find the condition node by type (if_condition)
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "if_condition") {
                conditionNode = child;
                break;
            }
        }
        
        if (!TreeSitterParser.isValid(conditionNode) || !TreeSitterParser.isValid(bodyNode)) {
            throw new ParseError("While statement missing condition or body", loc);
        }
        
        // The if_condition wraps the actual expression, need to get the inner expression
        TSNode innerExpr = TreeSitterParser.getChild(conditionNode, 1);  // Skip "("
        if (!TreeSitterParser.isValid(innerExpr)) {
            // Try direct child if structure is different
            innerExpr = conditionNode;
        }
        
        Expression condition = parseExpression(innerExpr);
        Statement body_ = parseStatement(bodyNode);
        
        return new WhileStatement(loc, condition, body_);
    }
    
    /**
     * Parse for statement
     */
    ForStatement parseForStatement(TSNode node, SourceLocation loc) {
        TSNode initNode = TreeSitterParser.getChildByFieldName(node, "init");
        TSNode conditionNode = TreeSitterParser.getChildByFieldName(node, "test");  // tree-sitter uses "test" not "condition"
        TSNode updateNode = TreeSitterParser.getChildByFieldName(node, "step");     // tree-sitter uses "step" not "update"
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");
        
        if (!TreeSitterParser.isValid(bodyNode)) {
            throw new ParseError("For statement missing body", loc);
        }
        
        Statement init = TreeSitterParser.isValid(initNode) ? parseStatement(initNode) : null;
        Expression condition = TreeSitterParser.isValid(conditionNode) ? parseExpression(conditionNode) : null;
        Expression update = TreeSitterParser.isValid(updateNode) ? parseExpression(updateNode) : null;
        Statement body_ = parseStatement(bodyNode);
        
        return new ForStatement(loc, init, condition, update, body_);
    }
    
    /**
     * Parse variable declaration as a statement (for local variables)
     * Structure: variable_declaration with children: type, declarator, ;
     * The declarator contains the name and optional initializer.
     */
    VariableDeclarationStatement parseVariableDeclarationStatement(TSNode node, SourceLocation loc) {
        // Variable declaration structure (from tree-sitter):
        //   Child 0: type
        //   Child 1: declarator (contains name and optional initializer)
        //   Child 2: ;
        
        TSNode typeNode, declaratorNode;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "type") {
                typeNode = child;
            } else if (childType == "declarator") {
                declaratorNode = child;
            }
        }
        
        if (!TreeSitterParser.isValid(typeNode)) {
            throw new ParseError("Variable declaration missing type", loc);
        }
        if (!TreeSitterParser.isValid(declaratorNode)) {
            throw new ParseError("Variable declaration missing declarator", loc);
        }
        
        Type varType = parseType(typeNode);
        
        // Parse the declarator - it may contain just a name, or name = initializer
        // Structure varies: could be just identifier, or identifier = expression
        // Pattern: [identifier] [=] [expression]
        //   - First identifier is the variable name
        //   - After =, anything (including identifier) is the initializer
        string name;
        Expression initializer = null;
        bool sawEquals = false;
        
        uint declChildCount = TreeSitterParser.getChildCount(declaratorNode);
        
        if (declChildCount == 0) {
            // The declarator itself is the identifier
            name = TreeSitterParser.getNodeText(declaratorNode, sourceText);
        } else {
            // Look for identifier, =, and initializer in children
            for (uint i = 0; i < declChildCount; i++) {
                TSNode child = TreeSitterParser.getChild(declaratorNode, i);
                string childType = TreeSitterParser.getNodeType(child);
                
                if (childType == "=") {
                    sawEquals = true;
                } else if (!sawEquals && childType == "identifier" && name.length == 0) {
                    // First identifier before = is the variable name
                    name = TreeSitterParser.getNodeText(child, sourceText);
                } else if (sawEquals) {
                    // Everything after = is the initializer expression
                    initializer = parseExpression(child);
                }
            }
        }
        
        if (name.length == 0) {
            throw new ParseError("Variable declaration missing name", loc);
        }
        
        return new VariableDeclarationStatement(loc, name, varType, initializer);
    }
    
    /**
     * Parse return statement
     */
    ReturnStatement parseReturnStatement(TSNode node, SourceLocation loc) {
        // Return statement structure: return [expression]
        TSNode expressionNode;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            
            if (nodeType == "expression") {
                expressionNode = child;
                break;
            }
        }
        
        Expression value = TreeSitterParser.isValid(expressionNode) ? parseExpression(expressionNode) : null;
        return new ReturnStatement(loc, value);
    }
    
    /**
     * Parse expression statement
     */
    ExpressionStatement parseExpressionStatement(TSNode node, SourceLocation loc) {
        TSNode exprNode = TreeSitterParser.getChildByFieldName(node, "expression");
        
        if (!TreeSitterParser.isValid(exprNode)) {
            // Try to find expression in children
            uint childCount = TreeSitterParser.getChildCount(node);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                string nodeType = TreeSitterParser.getNodeType(child);
                
                if (nodeType == "expression_list" || nodeType == "expression" || nodeType.endsWith("expression")) {
                    exprNode = child;
                    break;
                }
            }
        }
        
        if (!TreeSitterParser.isValid(exprNode)) {
            throw new ParseError("Expression statement missing expression", loc);
        }
        
        // Handle expression_list by taking the first expression
        string nodeType = TreeSitterParser.getNodeType(exprNode);
        if (nodeType == "expression_list") {
            uint childCount = TreeSitterParser.getChildCount(exprNode);
            log(3, "DEBUG expression_list has ", childCount, " children:");
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(exprNode, i);
                string childType = TreeSitterParser.getNodeType(child);
                string fieldName = TreeSitterParser.getChildFieldName(exprNode, i);
                log(3, "  Child ", i, ": ", childType, " (field: ", fieldName, ") = ", TreeSitterParser.getNodeText(child, sourceText));
                if (childType != "," && childType != "(" && childType != ")") {
                    exprNode = child;
                    break;
                }
            }
        }
        
        Expression expression = parseExpression(exprNode);
        return new ExpressionStatement(loc, expression);
    }
    
    /**
     * Parse expression from tree-sitter node
     */
    Expression parseExpression(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        string nodeType = TreeSitterParser.getNodeType(node);
        
        // Handle expression wrapper node or specific expression types that are just wrappers
        if (nodeType == "expression" || nodeType == "unary_expression" || nodeType == "binary_expression") {
            uint childCount = TreeSitterParser.getChildCount(node);
            if (childCount == 1) {
                return parseExpression(TreeSitterParser.getChild(node, 0));
            }
        }
        
        switch (nodeType) {
            case "expression_list":
                // Take the first expression from the list
                if (TreeSitterParser.getChildCount(node) > 0) {
                    return parseExpression(TreeSitterParser.getChild(node, 0));
                }
                throw new ParseError("Empty expression_list", loc);
            case "binary_expression":
            case "add_expression":
            case "mul_expression":
            case "rel_expression":
            case "equal_expression":
            case "and_expression":
            case "or_expression":
            case "xor_expression":
            case "shift_expression":
            case "logical_and_expression":
            case "logical_or_expression":
                return parseBinaryExpression(node, loc);
            case "postfix_expression":
                return parsePostfixExpression(node, loc);
            case "unary_expression":
                return parseUnaryExpression(node, loc);
            case "call_expression":
                return parseCallExpression(node, loc);
            case "import_expression":
                return parseImportExpression(node, loc);
            case "index_expression":
                return parseIndexExpression(node, loc);
            case "index":
                // "index" is the index value within an index_expression, not a full expression
                // Just parse its child
                if (TreeSitterParser.getChildCount(node) > 0) {
                    return parseExpression(TreeSitterParser.getChild(node, 0));
                }
                throw new ParseError("Empty index node", loc);
            case "member_expression":
                return parseMemberExpression(node, loc);
            case "identifier":
                return new IdentifierExpression(loc, TreeSitterParser.getNodeText(node, sourceText));
            case "this":
                return new IdentifierExpression(loc, "this");
            case "int_literal":
                return LiteralExpression.integer(loc, parseIntLiteral(TreeSitterParser.getNodeText(node, sourceText)));
            case "float_literal":
                return LiteralExpression.floating(loc, to!double(TreeSitterParser.getNodeText(node, sourceText)));
            case "string_literal": {
                string text = TreeSitterParser.getNodeText(node, sourceText);
                // Remove quotes and unescape the string
                string unescaped = unescapeString(text[1..$-1]);
                return LiteralExpression.string_(loc, unescaped);
            }
            case "bool_literal":
            case "true":
            case "false": {
                string text = TreeSitterParser.getNodeText(node, sourceText);
                return LiteralExpression.boolean(loc, text == "true");
            }
            case "null_literal":
                return LiteralExpression.null_(loc);
            case "char_literal": {
                string text = TreeSitterParser.getNodeText(node, sourceText);
                // Remove quotes: 'a' -> a
                if (text.length >= 2) {
                    char c = text[1];
                    // Handle escape sequences
                    if (text.length >= 3 && text[1] == '\\') {
                        switch (text[2]) {
                            case 'n': c = '\n'; break;
                            case 't': c = '\t'; break;
                            case 'r': c = '\r'; break;
                            case '0': c = '\0'; break;
                            case '\\': c = '\\'; break;
                            case '\'': c = '\''; break;
                            default: c = text[2]; break;
                        }
                    }
                    return LiteralExpression.char_(loc, c);
                }
                throw new ParseError("Invalid char literal: " ~ text, loc);
            }
            case "array_literal":
                return parseArrayLiteral(node, loc);
            case "cast_expression":
                return parseCastExpression(node, loc);
            case "assignment_expression":
                return parseAssignmentExpression(node, loc);
            case "property_expression":
                return parsePropertyExpression(node, loc);
            case "primary_expression":
                // primary_expression wraps parenthesized expressions, literals, identifiers
                // Just parse its first non-paren child
                for (uint i = 0; i < TreeSitterParser.getChildCount(node); i++) {
                    auto child = TreeSitterParser.getChild(node, i);
                    string childType = TreeSitterParser.getNodeType(child);
                    if (childType != "(" && childType != ")") {
                        return parseExpression(child);
                    }
                }
                throw new ParseError("Empty primary_expression", loc);
            default:
                throw new ParseError("Unknown expression node: " ~ nodeType, loc);
        }
    }
    
    /**
     * Parse binary expression
     */
    BinaryExpression parseBinaryExpression(TSNode node, SourceLocation loc) {
        TSNode leftNode, operatorNode, rightNode;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        if (childCount >= 3) {
            // Usually: left operator right
            leftNode = TreeSitterParser.getChild(node, 0);
            operatorNode = TreeSitterParser.getChild(node, 1);
            rightNode = TreeSitterParser.getChild(node, 2);
        } else {
            // Try field names just in case
            leftNode = TreeSitterParser.getChildByFieldName(node, "left");
            operatorNode = TreeSitterParser.getChildByFieldName(node, "operator");
            rightNode = TreeSitterParser.getChildByFieldName(node, "right");
        }
        
        if (!TreeSitterParser.isValid(leftNode) || !TreeSitterParser.isValid(operatorNode) || !TreeSitterParser.isValid(rightNode)) {
            // For binary expressions with 1 child (wrappers), they should have been caught in parseExpression
            throw new ParseError("Binary expression missing operands or operator: " ~ TreeSitterParser.getNodeType(node), loc);
        }
        
        Expression left = parseExpression(leftNode);
        Expression right = parseExpression(rightNode);
        BinaryExpression.Operator operator = parseBinaryOperator(TreeSitterParser.getNodeText(operatorNode, sourceText));
        
        return new BinaryExpression(loc, left, operator, right);
    }
    
    /**
     * Convert operator string to enum
     */
    BinaryExpression.Operator parseBinaryOperator(string opStr) {
        switch (opStr) {
            case "+": return BinaryExpression.Operator.Add;
            case "-": return BinaryExpression.Operator.Subtract;
            case "*": return BinaryExpression.Operator.Multiply;
            case "/": return BinaryExpression.Operator.Divide;
            case "%": return BinaryExpression.Operator.Modulo;
            case "==": return BinaryExpression.Operator.Equal;
            case "!=": return BinaryExpression.Operator.NotEqual;
            case "<": return BinaryExpression.Operator.Less;
            case "<=": return BinaryExpression.Operator.LessEqual;
            case ">": return BinaryExpression.Operator.Greater;
            case ">=": return BinaryExpression.Operator.GreaterEqual;
            case "&&": return BinaryExpression.Operator.LogicalAnd;
            case "||": return BinaryExpression.Operator.LogicalOr;
            case "&": return BinaryExpression.Operator.BitwiseAnd;
            case "|": return BinaryExpression.Operator.BitwiseOr;
            case "^": return BinaryExpression.Operator.BitwiseXor;
            case "<<": return BinaryExpression.Operator.ShiftLeft;
            case ">>": return BinaryExpression.Operator.ShiftRight;
            case ">>>": return BinaryExpression.Operator.UnsignedShiftRight;
            case "~": return BinaryExpression.Operator.Concat;
            default:
                throw new ParseError("Unknown binary operator: " ~ opStr, SourceLocation());
        }
    }
    
    /**
     * Parse unary expression (placeholder implementation)
     */
    UnaryExpression parseUnaryExpression(TSNode node, SourceLocation loc) {
        TSNode operatorNode = TreeSitterParser.getChildByFieldName(node, "operator");
        TSNode operandNode = TreeSitterParser.getChildByFieldName(node, "operand");
        
        if (!TreeSitterParser.isValid(operatorNode) || !TreeSitterParser.isValid(operandNode)) {
            // Some grammars might not use field names for unary operators
            uint childCount = TreeSitterParser.getChildCount(node);
            if (childCount >= 2) {
                operatorNode = TreeSitterParser.getChild(node, 0);
                operandNode = TreeSitterParser.getChild(node, 1);
            } else {
                throw new ParseError("Unary expression missing operator or operand", loc);
            }
        }
        
        string opStr = TreeSitterParser.getNodeText(operatorNode, sourceText);
        UnaryExpression.Operator op = parseUnaryOperator(opStr);
        Expression operand = parseExpression(operandNode);
        
        return new UnaryExpression(loc, op, operand, false);
    }

    UnaryExpression.Operator parseUnaryOperator(string opStr) {
        switch (opStr) {
            case "+": return UnaryExpression.Operator.Plus;
            case "-": return UnaryExpression.Operator.Minus;
            case "!": return UnaryExpression.Operator.LogicalNot;
            case "~": return UnaryExpression.Operator.BitwiseNot;
            case "++": return UnaryExpression.Operator.PreIncrement;
            case "--": return UnaryExpression.Operator.PreDecrement;
            case "&": return UnaryExpression.Operator.AddressOf;
            case "*": return UnaryExpression.Operator.Dereference;
            default:
                throw new ParseError("Unknown unary operator: " ~ opStr, SourceLocation());
        }
    }
    
    /**
     * Parse array literal: [1, 2, 3]
     */
    ArrayLiteralExpression parseArrayLiteral(TSNode node, SourceLocation loc) {
        Expression[] elements;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            // Skip brackets and commas
            if (childType == "[" || childType == "]" || childType == ",") {
                continue;
            }
            
            // Parse element expression
            elements ~= parseExpression(child);
        }
        
        return new ArrayLiteralExpression(loc, elements);
    }
    
    /**
     * Parse postfix expression (i++, i--)
     */
    UnaryExpression parsePostfixExpression(TSNode node, SourceLocation loc) {
        // Postfix expression has operand first, then operator
        // Structure: operand ++  or  operand --
        TSNode operandNode, operatorNode;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        if (childCount >= 2) {
            operandNode = TreeSitterParser.getChild(node, 0);
            operatorNode = TreeSitterParser.getChild(node, childCount - 1);
        } else {
            throw new ParseError("Postfix expression missing operand or operator", loc);
        }
        
        string opStr = TreeSitterParser.getNodeText(operatorNode, sourceText);
        UnaryExpression.Operator op;
        if (opStr == "++") {
            op = UnaryExpression.Operator.PostIncrement;
        } else if (opStr == "--") {
            op = UnaryExpression.Operator.PostDecrement;
        } else {
            throw new ParseError("Unknown postfix operator: " ~ opStr, loc);
        }
        
        Expression operand = parseExpression(operandNode);
        return new UnaryExpression(loc, op, operand, true);
    }
    
    /**
     * Parse call expression (placeholder implementation)
     */
    CallExpression parseCallExpression(TSNode node, SourceLocation loc) {
        TSNode functionNode = TreeSitterParser.getChildByFieldName(node, "function");
        TSNode argumentsNode = TreeSitterParser.getChildByFieldName(node, "arguments");
        
        if (!TreeSitterParser.isValid(functionNode)) {
            functionNode = TreeSitterParser.getChild(node, 0);
        }
        
        if (!TreeSitterParser.isValid(functionNode)) {
            throw new ParseError("Call expression missing function", loc);
        }
        
        Expression function_;
        string funcNodeType = TreeSitterParser.getNodeType(functionNode);
        
        // Handle "type" node which tree-sitter uses for qualified identifiers like "module.func"
        if (funcNodeType == "type") {
            string qualifiedName = TreeSitterParser.getNodeText(functionNode, sourceText);
            function_ = parseQualifiedIdentifier(qualifiedName, loc);
        } else {
            function_ = parseExpression(functionNode);
        }
        
        Expression[] arguments;
        
        if (!TreeSitterParser.isValid(argumentsNode)) {
            // Look for arguments in other nodes like named_arguments
            uint childCount = TreeSitterParser.getChildCount(node);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                string type = TreeSitterParser.getNodeType(child);
                if (type == "named_arguments" || type == "arguments") {
                    argumentsNode = child;
                    break;
                }
            }
        }
        
        if (TreeSitterParser.isValid(argumentsNode)) {
            uint childCount = TreeSitterParser.getChildCount(argumentsNode);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(argumentsNode, i);
                string nodeType = TreeSitterParser.getNodeType(child);
                
                if (nodeType != "(" && nodeType != ")" && nodeType != ",") {
                    try {
                        if (nodeType == "named_argument") {
                            // Find the actual expression inside named_argument
                            uint innerCount = TreeSitterParser.getChildCount(child);
                            for (uint j = 0; j < innerCount; j++) {
                                TSNode inner = TreeSitterParser.getChild(child, j);
                                string innerType = TreeSitterParser.getNodeType(inner);
                                if (innerType.endsWith("expression") || innerType == "identifier" || innerType.endsWith("literal")) {
                                    arguments ~= parseExpression(inner);
                                    break;
                                }
                            }
                        } else {
                            arguments ~= parseExpression(child);
                        }
                    } catch (ParseError e) {
                        // Skip punctuation or garbage
                    }
                }
            }
        }
        
        return new CallExpression(loc, function_, arguments);
    }
    
    /**
     * Parse index expression (placeholder implementation)
     */
    Expression parseIndexExpression(TSNode node, SourceLocation loc) {
        // Structure: array '[' index ']' (4 children)
        // OR for slices: array '[' start '..' end ']' where index contains 'start..end'
        uint childCount = TreeSitterParser.getChildCount(node);
        
        if (childCount < 4) {
            throw new ParseError("Index expression has wrong structure", loc);
        }
        
        TSNode arrayNode = TreeSitterParser.getChild(node, 0);
        TSNode indexNode = TreeSitterParser.getChild(node, 2);  // child 1 is '[', child 2 is index
        
        Expression array = parseExpression(arrayNode);
        
        // Check if this is a slice expression by looking for '..' in the index text
        string indexText = TreeSitterParser.getNodeText(indexNode, sourceText);
        import std.string : indexOf;
        auto dotdotPos = indexOf(indexText, "..");
        
        if (dotdotPos >= 0) {
            // This is a slice expression: arr[start..end]
            // Parse start and end from the text
            import std.conv : to;
            import std.string : strip;
            
            string startText = indexText[0..dotdotPos].strip();
            string endText = indexText[dotdotPos+2..$].strip();
            
            // Parse start and end as expressions (for now, just integers)
            Expression startExpr = LiteralExpression.integer(loc, to!long(startText));
            Expression endExpr = LiteralExpression.integer(loc, to!long(endText));
            
            return new SliceExpression(loc, array, startExpr, endExpr);
        }
        
        // Regular index expression
        Expression index = parseExpression(indexNode);
        return new IndexExpression(loc, array, index);
    }
    
    /**
     * Parse import expression: import("filename")
     * D's compile-time file import.
     */
    ImportExpression parseImportExpression(TSNode node, SourceLocation loc) {
        // Find the string literal argument (may be wrapped in "expression" node)
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            
            if (nodeType == "string_literal") {
                string text = TreeSitterParser.getNodeText(child, sourceText);
                // Remove quotes
                string filename = text[1..$-1];
                return new ImportExpression(loc, filename);
            }
            
            // tree-sitter wraps the argument in "expression" node
            if (nodeType == "expression") {
                // Look for string_literal inside
                uint innerCount = TreeSitterParser.getChildCount(child);
                for (uint j = 0; j < innerCount; j++) {
                    TSNode inner = TreeSitterParser.getChild(child, j);
                    string innerType = TreeSitterParser.getNodeType(inner);
                    if (innerType == "string_literal") {
                        string text = TreeSitterParser.getNodeText(inner, sourceText);
                        string filename = text[1..$-1];
                        return new ImportExpression(loc, filename);
                    }
                }
            }
        }
        
        throw new ParseError("import() requires a string literal argument", loc);
    }
    
    /**
     * Parse member expression (placeholder implementation)
     */
    MemberExpression parseMemberExpression(TSNode node, SourceLocation loc) {
        TSNode objectNode = TreeSitterParser.getChildByFieldName(node, "object");
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        
        if (!TreeSitterParser.isValid(objectNode) || !TreeSitterParser.isValid(nameNode)) {
            throw new ParseError("Member expression missing object or member name", loc);
        }
        
        Expression object = parseExpression(objectNode);
        string name = TreeSitterParser.getNodeText(nameNode, sourceText);
        
        return new MemberExpression(loc, object, name);
    }
    
    /**
     * Parse cast expression: cast(Type)expression
     */
    CastExpression parseCastExpression(TSNode node, SourceLocation loc) {
        import std.exception : enforce;
        
        // Structure per tree-sitter-d grammar:
        //   - child node of type "type" (the target type)
        //   - field "operand" (the expression being cast)
        
        // Find type child by node type
        TSNode typeNode;
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            if (TreeSitterParser.getNodeType(child) == "type") {
                typeNode = child;
                break;
            }
        }
        
        // Get operand by field name
        TSNode operandNode = TreeSitterParser.getChildByFieldName(node, "operand");
        
        // Enforce grammar expectations
        enforce(TreeSitterParser.isValid(typeNode),
            "cast_expression: expected 'type' child node (tree-sitter-d grammar may have changed)");
        enforce(TreeSitterParser.isValid(operandNode),
            "cast_expression: expected 'operand' field (tree-sitter-d grammar may have changed)");
        
        Type targetType = parseType(typeNode);
        Expression expression = parseExpression(operandNode);
        
        return new CastExpression(loc, targetType, expression);
    }
    
    /**
     * Parse assignment expression
     * Structure: left_operand operator right_operand
     */
    AssignmentExpression parseAssignmentExpression(TSNode node, SourceLocation loc) {
        // Try field-based access first
        TSNode leftNode = TreeSitterParser.getChildByFieldName(node, "left");
        TSNode operatorNode = TreeSitterParser.getChildByFieldName(node, "operator");
        TSNode rightNode = TreeSitterParser.getChildByFieldName(node, "right");
        
        // If field-based access fails, parse by position
        if (!TreeSitterParser.isValid(leftNode) || !TreeSitterParser.isValid(rightNode)) {
            // Structure: left = right  (3 children: left, operator, right)
            uint childCount = TreeSitterParser.getChildCount(node);
            if (childCount >= 3) {
                leftNode = TreeSitterParser.getChild(node, 0);
                operatorNode = TreeSitterParser.getChild(node, 1);
                rightNode = TreeSitterParser.getChild(node, 2);
            } else {
                throw new ParseError(
                    format("Assignment expression has unexpected structure (%d children)", childCount), loc);
            }
        }
        
        if (!TreeSitterParser.isValid(leftNode) || !TreeSitterParser.isValid(rightNode)) {
            throw new ParseError("Assignment expression missing operands", loc);
        }
        
        Expression left = parseExpression(leftNode);
        Expression right = parseExpression(rightNode);
        string opStr = TreeSitterParser.getNodeText(operatorNode, sourceText);
        AssignmentExpression.Operator op = parseAssignmentOperator(opStr);
        
        return new AssignmentExpression(loc, left, op, right);
    }

    AssignmentExpression.Operator parseAssignmentOperator(string opStr) {
        switch (opStr) {
            case "=": return AssignmentExpression.Operator.Assign;
            case "+=": return AssignmentExpression.Operator.AddAssign;
            case "-=": return AssignmentExpression.Operator.SubtractAssign;
            case "*=": return AssignmentExpression.Operator.MultiplyAssign;
            case "/=": return AssignmentExpression.Operator.DivideAssign;
            case "%=": return AssignmentExpression.Operator.ModuloAssign;
            case "&=": return AssignmentExpression.Operator.AndAssign;
            case "|=": return AssignmentExpression.Operator.OrAssign;
            case "^=": return AssignmentExpression.Operator.XorAssign;
            case "<<=": return AssignmentExpression.Operator.ShiftLeftAssign;
            case ">>=": return AssignmentExpression.Operator.ShiftRightAssign;
            case "~=": return AssignmentExpression.Operator.ConcatAssign;
            default:
                throw new ParseError("Unknown assignment operator: " ~ opStr, SourceLocation());
        }
    }
    
    /**
     * Parse a qualified identifier like "module.func" into a MemberExpression chain.
     * For "a.b.c", produces MemberExpression(MemberExpression(IdentifierExpression("a"), "b"), "c")
     */
    Expression parseQualifiedIdentifier(string qualifiedName, SourceLocation loc) {
        import std.array : split;
        
        auto parts = qualifiedName.split(".");
        if (parts.length == 0) {
            throw new ParseError("Empty qualified identifier", loc);
        }
        
        // Start with the first part as an identifier
        Expression result = new IdentifierExpression(loc, parts[0]);
        
        // Chain member accesses for remaining parts
        foreach (part; parts[1..$]) {
            result = new MemberExpression(loc, result, part);
        }
        
        return result;
    }
    
    /**
     * Parse property expression (e.g., Type.sizeof, var.length)
     * This handles both type properties and value properties
     */
    Expression parsePropertyExpression(TSNode node, SourceLocation loc) {
        // Property expression structure: object "." property
        uint childCount = TreeSitterParser.getChildCount(node);
        
        Expression object;
        string propertyName;
        
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            
            if (childType == "identifier") {
                if (object is null) {
                    // First identifier is the object/type
                    object = new IdentifierExpression(loc, TreeSitterParser.getNodeText(child, sourceText));
                } else {
                    // Second identifier is the property name
                    propertyName = TreeSitterParser.getNodeText(child, sourceText);
                }
            } else if (childType == "." || childType == "property_identifier") {
                // Skip dot, but property_identifier is the property name
                if (childType == "property_identifier") {
                    propertyName = TreeSitterParser.getNodeText(child, sourceText);
                }
            } else if (childType != ".") {
                // Some other expression as the object
                object = parseExpression(child);
            }
        }
        
        if (object is null) {
            throw new ParseError("Property expression missing object", loc);
        }
        if (propertyName.length == 0) {
            throw new ParseError("Property expression missing property name", loc);
        }
        
        return new MemberExpression(loc, object, propertyName);
    }
    
    /**
     * Create source location from tree-sitter node
     */
    SourceLocation makeSourceLocation(TSNode node) {
        import parser.tree_sitter_c : ts_node_start_byte, ts_node_end_byte;
        
        auto startPoint = TreeSitterParser.getStartPoint(node);
        auto endPoint = TreeSitterParser.getEndPoint(node);
        
        return SourceLocation(
            filename,
            startPoint.row + 1,  // tree-sitter uses 0-based rows
            startPoint.column + 1,  // tree-sitter uses 0-based columns
            ts_node_start_byte(node),
            ts_node_end_byte(node)
        );
    }
}