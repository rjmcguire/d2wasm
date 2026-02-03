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
            import std.stdio : writeln;
            
            if (!TreeSitterParser.isValid(root)) {
                throw new ParseError("Invalid parse tree root", SourceLocation(filename, 1, 1, 0, 0));
            }
            
            if (TreeSitterParser.hasError(root)) {
                throw new ParseError("Parse errors in source file", SourceLocation(filename, 1, 1, 0, 0));
            }
            
            Declaration[] declarations;
            
            uint childCount = TreeSitterParser.getChildCount(root);
            writeln("Root has ", childCount, " children");
            
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(root, i);
                if (!TreeSitterParser.isValid(child)) {
                    writeln("Warning: Invalid child node at index ", i);
                    continue;
                }
                
                string nodeType = TreeSitterParser.getNodeType(child);
                writeln("Processing child ", i, " of type: ", nodeType);
                
                try {
                    if (nodeType == "function_declaration") {
                        auto decl = parseFunctionDeclaration(child);
                        declarations ~= decl;
                        writeln("Successfully parsed function declaration");
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
                    } else if (nodeType != "comment" && nodeType.length > 0) {
                        writeln("Warning: Skipping unknown top-level node: ", nodeType);
                    }
                } catch (ParseError e) {
                    writeln("Parse error in ", nodeType, ": ", e.msg);
                    // Continue parsing other declarations
                } catch (Exception e) {
                    writeln("Unexpected error in ", nodeType, ": ", e.msg);
                    // Continue parsing other declarations
                }
            }
            
            return declarations;
        } catch (Exception e) {
            import std.stdio : writeln;
            writeln("Exception in parseSourceFileNode: ", e.msg);
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
                writeln("Parsed WASM import: ", moduleName, ".", name);
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
                try {
                    statements ~= parseStatement(child);
                } catch (ParseError e) {
                    writeln("Warning: Skipping statement due to parse error: ", e.msg);
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
        
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        if (!TreeSitterParser.isValid(nameNode)) {
            throw new ParseError("Class declaration missing name", loc);
        }
        
        string name = TreeSitterParser.getNodeText(nameNode, sourceText);
        
        // TODO: Parse base class and interfaces
        Type baseClass = null;
        Type[] interfaces;
        
        // TODO: Parse class members
        Declaration[] members;
        
        return new ClassDecl(loc, name, baseClass, interfaces, members);
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
        
        return new StructDecl(loc, name, members);
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
            }
            // Skip braces, semicolons, etc.
        }
        
        return members;
    }
    
    /**
     * Parse interface declaration
     */
    InterfaceDecl parseInterfaceDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        if (!TreeSitterParser.isValid(nameNode)) {
            throw new ParseError("Interface declaration missing name", loc);
        }
        
        string name = TreeSitterParser.getNodeText(nameNode, sourceText);
        
        // TODO: Parse parent interfaces and methods
        Type[] parentInterfaces;
        FunctionDecl[] methods;
        
        return new InterfaceDecl(loc, name, parentInterfaces, methods);
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
        
        writeln("Parsed manifest constant: ", name, " = ", initializer.toString());
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
        
        writeln("Parsed mixin declaration: mixin(", mixinArg.toString(), ")");
        
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
        writeln("Parsing conditional_declaration with ", TreeSitterParser.getChildCount(node), " children:");
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            writeln("  Child ", i, ": ", childType);
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
        
        writeln("Parsed static if: condition=", conditionExpr.toString(), 
                ", then=", thenDecls.length, " decls, else=", elseDecls.length, " decls");
        
        return new StaticIfDecl(loc, conditionExpr, thenDecls, elseDecls);
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
        
        writeln("  Parsing declaration node of type: ", nodeType);
        
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
        writeln("  Warning: Unknown declaration node type: ", nodeType);
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
            // Look for the actual type inside the type node, skipping type_ctor
            uint childCount = TreeSitterParser.getChildCount(node);
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
                // String is represented as a user-defined type for now
                return new UserType(loc, "string");
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
        writeln("Parsing statement: ", nodeType, " with ", TreeSitterParser.getChildCount(node), " children");
        for (uint i = 0; i < TreeSitterParser.getChildCount(node); i++) {
            writeln("  Child ", i, ": ", TreeSitterParser.getNodeType(TreeSitterParser.getChild(node, i)), 
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
        
        writeln("Parsed mixin statement: mixin(", mixinArg.toString(), ")");
        
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
                statements ~= parseStatement(child);
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
        TSNode conditionNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");
        
        if (!TreeSitterParser.isValid(conditionNode) || !TreeSitterParser.isValid(bodyNode)) {
            throw new ParseError("While statement missing condition or body", loc);
        }
        
        Expression condition = parseExpression(conditionNode);
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
            writeln("DEBUG expression_list has ", childCount, " children:");
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(exprNode, i);
                string childType = TreeSitterParser.getNodeType(child);
                string fieldName = TreeSitterParser.getChildFieldName(exprNode, i);
                writeln("  Child ", i, ": ", childType, " (field: ", fieldName, ") = ", TreeSitterParser.getNodeText(child, sourceText));
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
                return parseBinaryExpression(node, loc);
            case "postfix_expression":
                return parsePostfixExpression(node, loc);
            case "unary_expression":
                return parseUnaryExpression(node, loc);
            case "call_expression":
                return parseCallExpression(node, loc);
            case "index_expression":
                return parseIndexExpression(node, loc);
            case "member_expression":
                return parseMemberExpression(node, loc);
            case "identifier":
                return new IdentifierExpression(loc, TreeSitterParser.getNodeText(node, sourceText));
            case "int_literal":
                return LiteralExpression.integer(loc, to!long(TreeSitterParser.getNodeText(node, sourceText)));
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
    IndexExpression parseIndexExpression(TSNode node, SourceLocation loc) {
        TSNode arrayNode = TreeSitterParser.getChildByFieldName(node, "array");
        TSNode indexNode = TreeSitterParser.getChildByFieldName(node, "index");
        
        if (!TreeSitterParser.isValid(arrayNode) || !TreeSitterParser.isValid(indexNode)) {
            throw new ParseError("Index expression missing array or index", loc);
        }
        
        Expression array = parseExpression(arrayNode);
        Expression index = parseExpression(indexNode);
        
        return new IndexExpression(loc, array, index);
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
     * Parse cast expression (placeholder implementation)
     */
    CastExpression parseCastExpression(TSNode node, SourceLocation loc) {
        TSNode typeNode = TreeSitterParser.getChildByFieldName(node, "type");
        TSNode exprNode = TreeSitterParser.getChildByFieldName(node, "expression");
        
        if (!TreeSitterParser.isValid(typeNode) || !TreeSitterParser.isValid(exprNode)) {
            throw new ParseError("Cast expression missing type or expression", loc);
        }
        
        Type targetType = parseType(typeNode);
        Expression expression = parseExpression(exprNode);
        
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