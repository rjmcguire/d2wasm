/**
 * Tree-sitter bridge for C source files (importC support).
 *
 * Maps tree-sitter-c parse tree nodes to the existing D AST types.
 * Handles: functions, structs, enums, typedefs, global variables,
 * and simple function bodies (arithmetic, control flow, calls,
 * struct field access).
 *
 * Preprocessed input expected — leftover `#` directives are skipped.
 */
module parser.c_tree_sitter_bridge;

import ast.nodes;
import ast.statements;
import ast.expressions;
import parser.tree_sitter_c;
import std.string;
import std.conv;
import std.algorithm;
import std.array : split;
import diagnostic.log : log;

/**
 * Bridge that converts a tree-sitter-c parse tree into AST declarations.
 */
class CTreeSitterBridge {
    string filename;
    string sourceText;
    TreeSitterParser parser;

    this(string filename, string sourceText) {
        this.filename = filename;
        this.sourceText = sourceText;
        this.parser = new TreeSitterParser(tree_sitter_c());
    }

    // ------------------------------------------------------------------
    // Top-level entry point
    // ------------------------------------------------------------------

    Declaration[] parseSourceFile() {
        auto root = parser.parseString(sourceText);
        if (!TreeSitterParser.isValid(root))
            throw new ParseError("Invalid parse tree root",
                SourceLocation(filename, 1, 1, 0, 0));
        return parseTranslationUnit(root);
    }

    // ------------------------------------------------------------------
    // Translation unit (root)
    // ------------------------------------------------------------------

    private Declaration[] parseTranslationUnit(TSNode root) {
        Declaration[] declarations;

        uint childCount = TreeSitterParser.getChildCount(root);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(root, i);
            string nodeType = TreeSitterParser.getNodeType(child);

            // Skip preprocessor directives, comments, semicolons
            if (nodeType.startsWith("preproc") || nodeType == "comment"
                    || nodeType == ";" || nodeType.length == 0)
                continue;

            try {
                auto decls = parseTopLevel(child);
                declarations ~= decls;
            } catch (ParseError e) {
                log(2, "C parse error in ", nodeType, ": ", e.msg);
            }
        }
        return declarations;
    }

    // ------------------------------------------------------------------
    // Top-level dispatch
    // ------------------------------------------------------------------

    private Declaration[] parseTopLevel(TSNode node) {
        string nodeType = TreeSitterParser.getNodeType(node);
        SourceLocation loc = makeSourceLocation(node);

        switch (nodeType) {
        case "function_definition":
            return [parseFunctionDefinition(node, loc)];

        case "declaration":
            return parseDeclaration(node, loc);

        case "struct_specifier":
            auto sd = parseStructSpecifier(node, loc);
            if (sd !is null)
                return [sd];
            return [];

        case "enum_specifier":
            return parseEnumSpecifier(node, loc);

        case "type_definition":
            return parseTypedef(node, loc);

        default:
            // Silently skip anything we don't understand at top-level.
            log(3, "C bridge: skipping top-level node type: ", nodeType);
            return [];
        }
    }

    // ------------------------------------------------------------------
    // Function definition
    // ------------------------------------------------------------------

    private Declaration parseFunctionDefinition(TSNode node, SourceLocation loc) {
        TSNode typeNode = TreeSitterParser.getChildByFieldName(node, "type");
        TSNode declaratorNode = TreeSitterParser.getChildByFieldName(node, "declarator");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");

        // Return type
        Type returnType = TreeSitterParser.isValid(typeNode)
            ? mapCType(typeNode) : new BasicType(loc, BasicType.Kind.Void);

        // Declarator is a function_declarator: name + parameters
        string name;
        Parameter[] params;
        bool isPointerReturn;
        extractFunctionDeclarator(declaratorNode, returnType, name, params, isPointerReturn);
        if (isPointerReturn)
            returnType = new PointerType(loc, returnType);

        // Body
        Statement body_ = TreeSitterParser.isValid(bodyNode) ? parseCompoundStatement(bodyNode) : null;

        // Check for static storage class
        Visibility vis = Visibility.public_;
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            if (TreeSitterParser.getNodeType(child) == "storage_class_specifier") {
                string text = TreeSitterParser.getNodeText(child, sourceText);
                if (text == "static")
                    vis = Visibility.private_;
            }
        }

        auto func = new FunctionDecl(loc, name, returnType, params, body_);
        func.visibility = vis;
        return func;
    }

    // ------------------------------------------------------------------
    // Declarations (forward functions, variables)
    // ------------------------------------------------------------------

    private Declaration[] parseDeclaration(TSNode node, SourceLocation loc) {
        TSNode typeNode = TreeSitterParser.getChildByFieldName(node, "type");
        TSNode declaratorNode = TreeSitterParser.getChildByFieldName(node, "declarator");

        if (!TreeSitterParser.isValid(typeNode))
            return [];

        Type baseType = mapCType(typeNode);

        if (!TreeSitterParser.isValid(declaratorNode))
            return [];

        string declType = TreeSitterParser.getNodeType(declaratorNode);

        // Forward function declaration: int foo(int a);
        if (declType == "function_declarator" || declType == "pointer_declarator") {
            return [parseFunctionForwardDecl(declaratorNode, baseType, loc)];
        }

        // Variable with initializer: int x = 5;
        if (declType == "init_declarator") {
            return [parseInitDeclarator(declaratorNode, baseType, loc)];
        }

        // Simple variable: int x;
        if (declType == "identifier") {
            string name = TreeSitterParser.getNodeText(declaratorNode, sourceText);
            return [new VariableDecl(loc, name, baseType, null, true)];
        }

        return [];
    }

    private Declaration parseFunctionForwardDecl(TSNode declaratorNode, Type baseType, SourceLocation loc) {
        string declType = TreeSitterParser.getNodeType(declaratorNode);
        bool isPointerReturn = false;

        // pointer_declarator wraps the function_declarator for return-type pointers
        if (declType == "pointer_declarator") {
            isPointerReturn = true;
            // Find function_declarator inside
            uint count = TreeSitterParser.getChildCount(declaratorNode);
            for (uint i = 0; i < count; i++) {
                TSNode child = TreeSitterParser.getChild(declaratorNode, i);
                if (TreeSitterParser.getNodeType(child) == "function_declarator") {
                    declaratorNode = child;
                    break;
                }
            }
        }

        string name;
        Parameter[] params;
        bool ptrDummy;
        extractFunctionDeclarator(declaratorNode, baseType, name, params, ptrDummy);
        Type returnType = isPointerReturn ? new PointerType(loc, baseType) : baseType;

        auto func = new FunctionDecl(loc, name, returnType, params, null);
        func.visibility = Visibility.public_;
        return func;
    }

    private Declaration parseInitDeclarator(TSNode node, Type baseType, SourceLocation loc) {
        TSNode declNode = TreeSitterParser.getChildByFieldName(node, "declarator");
        TSNode valueNode = TreeSitterParser.getChildByFieldName(node, "value");

        Type varType = baseType;
        string name;

        if (TreeSitterParser.isValid(declNode)) {
            string declNodeType = TreeSitterParser.getNodeType(declNode);
            if (declNodeType == "pointer_declarator") {
                varType = new PointerType(loc, baseType);
                // Find the identifier inside
                name = extractIdentifierFromDeclarator(declNode);
            } else if (declNodeType == "identifier") {
                name = TreeSitterParser.getNodeText(declNode, sourceText);
            } else {
                name = TreeSitterParser.getNodeText(declNode, sourceText);
            }
        }

        Expression init_ = TreeSitterParser.isValid(valueNode)
            ? parseExpression(valueNode) : null;

        return new VariableDecl(loc, name, varType, init_, true);
    }

    // ------------------------------------------------------------------
    // Struct specifier
    // ------------------------------------------------------------------

    private Declaration parseStructSpecifier(TSNode node, SourceLocation loc) {
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");

        if (!TreeSitterParser.isValid(nameNode) || !TreeSitterParser.isValid(bodyNode))
            return null; // Forward struct declaration or anonymous — skip

        string name = TreeSitterParser.getNodeText(nameNode, sourceText);
        Declaration[] members;

        // body is a field_declaration_list
        uint childCount = TreeSitterParser.getChildCount(bodyNode);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(bodyNode, i);
            string childType = TreeSitterParser.getNodeType(child);

            if (childType == "field_declaration") {
                auto fieldDecl = parseFieldDeclaration(child);
                if (fieldDecl !is null)
                    members ~= fieldDecl;
            }
        }

        auto sd = new StructDecl(loc, name, members, true);
        return sd;
    }

    private Declaration parseFieldDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        TSNode typeNode = TreeSitterParser.getChildByFieldName(node, "type");
        TSNode declNode = TreeSitterParser.getChildByFieldName(node, "declarator");

        if (!TreeSitterParser.isValid(typeNode) || !TreeSitterParser.isValid(declNode))
            return null;

        Type fieldType = mapCType(typeNode);
        string declNodeType = TreeSitterParser.getNodeType(declNode);

        // Handle pointer fields
        if (declNodeType == "pointer_declarator") {
            fieldType = new PointerType(loc, fieldType);
            declNode = findInnerIdentifier(declNode);
            declNodeType = TreeSitterParser.getNodeType(declNode);
        }

        string name;
        if (declNodeType == "field_identifier")
            name = TreeSitterParser.getNodeText(declNode, sourceText);
        else
            name = TreeSitterParser.getNodeText(declNode, sourceText);

        return new VariableDecl(loc, name, fieldType, null, true);
    }

    // ------------------------------------------------------------------
    // Enum specifier → ManifestConstantDecl[]
    // ------------------------------------------------------------------

    private Declaration[] parseEnumSpecifier(TSNode node, SourceLocation loc) {
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");
        if (!TreeSitterParser.isValid(bodyNode))
            return [];

        Declaration[] decls;
        int nextValue = 0;

        uint childCount = TreeSitterParser.getChildCount(bodyNode);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(bodyNode, i);
            if (TreeSitterParser.getNodeType(child) != "enumerator")
                continue;

            TSNode nameNode = TreeSitterParser.getChildByFieldName(child, "name");
            TSNode valueNode = TreeSitterParser.getChildByFieldName(child, "value");

            if (!TreeSitterParser.isValid(nameNode))
                continue;

            string name = TreeSitterParser.getNodeText(nameNode, sourceText);
            SourceLocation enumLoc = makeSourceLocation(child);

            if (TreeSitterParser.isValid(valueNode)) {
                // Try to extract integer value for tracking sequential values
                string valText = TreeSitterParser.getNodeText(valueNode, sourceText).strip();
                try {
                    nextValue = to!int(valText);
                } catch (Exception) {
                    // Non-trivial expression — just use expression
                }
            }

            auto valExpr = LiteralExpression.integer(enumLoc, nextValue);
            auto manifest = new ManifestConstantDecl(enumLoc, name, valExpr);
            manifest.visibility = Visibility.public_;
            decls ~= manifest;
            nextValue++;
        }
        return decls;
    }

    // ------------------------------------------------------------------
    // Typedef → ManifestConstantDecl (type alias)
    // ------------------------------------------------------------------

    private Declaration[] parseTypedef(TSNode node, SourceLocation loc) {
        TSNode typeNode = TreeSitterParser.getChildByFieldName(node, "type");
        TSNode declNode = TreeSitterParser.getChildByFieldName(node, "declarator");

        if (!TreeSitterParser.isValid(typeNode) || !TreeSitterParser.isValid(declNode))
            return [];

        // The declarator contains the new name
        string newName;
        string declNodeType = TreeSitterParser.getNodeType(declNode);
        if (declNodeType == "type_identifier")
            newName = TreeSitterParser.getNodeText(declNode, sourceText);
        else if (declNodeType == "pointer_declarator") {
            // typedef int* IntPtr; → pointer type alias
            newName = extractIdentifierFromDeclarator(declNode);
        } else
            newName = TreeSitterParser.getNodeText(declNode, sourceText);

        // For now, represent typedef as a ManifestConstantDecl that the
        // symbol table will pick up. A more proper approach would be an
        // AliasDecl, but using the same pattern as D enum for simplicity.
        // The type checker can resolve typedefs via scope aliases.
        // We skip typedef for now and just return empty — the struct
        // definition itself is already registered.
        // TODO: proper alias support
        return [];
    }

    // ------------------------------------------------------------------
    // Type mapping: tree-sitter-c type nodes → AST types
    // ------------------------------------------------------------------

    private Type mapCType(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        string nodeType = TreeSitterParser.getNodeType(node);

        switch (nodeType) {
        case "primitive_type":
            return mapPrimitiveType(node, loc);

        case "sized_type_specifier":
            return mapSizedType(node, loc);

        case "struct_specifier":
            // struct X used as type → UserType("X")
            TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
            if (TreeSitterParser.isValid(nameNode)) {
                string name = TreeSitterParser.getNodeText(nameNode, sourceText);
                return new UserType(loc, name);
            }
            throw new ParseError("Anonymous struct type not supported", loc);

        case "enum_specifier":
            // enum used as type → Int32 (C enums are ints)
            return new BasicType(loc, BasicType.Kind.Int32);

        case "type_identifier":
            return new UserType(loc, TreeSitterParser.getNodeText(node, sourceText));

        case "type_descriptor":
            // type_descriptor wraps a type specifier (used in casts, sizeof)
            return mapTypeDescriptor(node, loc);

        default:
            // Try to read text and guess
            string text = TreeSitterParser.getNodeText(node, sourceText).strip();
            if (text == "void") return new BasicType(loc, BasicType.Kind.Void);
            if (text == "int") return new BasicType(loc, BasicType.Kind.Int32);
            if (text == "char") return new BasicType(loc, BasicType.Kind.Char);
            log(2, "C bridge: unknown type node '", nodeType, "' text='", text, "'");
            return new BasicType(loc, BasicType.Kind.Int32); // Default to int
        }
    }

    private Type mapPrimitiveType(TSNode node, SourceLocation loc) {
        string text = TreeSitterParser.getNodeText(node, sourceText);
        switch (text) {
        case "int": return new BasicType(loc, BasicType.Kind.Int32);
        case "char": return new BasicType(loc, BasicType.Kind.Char);
        case "void": return new BasicType(loc, BasicType.Kind.Void);
        case "float": return new BasicType(loc, BasicType.Kind.Float32);
        case "double": return new BasicType(loc, BasicType.Kind.Float64);
        case "bool": case "_Bool": return new BasicType(loc, BasicType.Kind.Bool);
        case "short": return new BasicType(loc, BasicType.Kind.Int16);
        case "long": return new BasicType(loc, BasicType.Kind.Int64);
        default:
            log(2, "C bridge: unknown primitive type '", text, "'");
            return new BasicType(loc, BasicType.Kind.Int32);
        }
    }

    private Type mapSizedType(TSNode node, SourceLocation loc) {
        string text = TreeSitterParser.getNodeText(node, sourceText).strip();

        // Normalize: remove extra spaces, lowercase
        // Common patterns: "unsigned int", "unsigned char", "long long",
        // "unsigned long", "short", "unsigned short", etc.
        bool isUnsigned = text.canFind("unsigned");
        bool isLong = text.canFind("long");
        bool isShort = text.canFind("short");

        // Check for "long long" by counting word occurrences
        size_t longCount = 0;
        foreach (word; text.split(" ")) {
            if (word == "long") longCount++;
        }
        if (longCount >= 2)
            return new BasicType(loc, isUnsigned ? BasicType.Kind.UInt64 : BasicType.Kind.Int64);
        if (isLong)
            return new BasicType(loc, isUnsigned ? BasicType.Kind.UInt64 : BasicType.Kind.Int64);
        if (isShort)
            return new BasicType(loc, isUnsigned ? BasicType.Kind.UInt16 : BasicType.Kind.Int16);
        if (isUnsigned && text.canFind("char"))
            return new BasicType(loc, BasicType.Kind.UInt8);
        if (isUnsigned)
            return new BasicType(loc, BasicType.Kind.UInt32);

        // Signed int / default
        return new BasicType(loc, BasicType.Kind.Int32);
    }

    private Type mapTypeDescriptor(TSNode node, SourceLocation loc) {
        // type_descriptor has a type child and optional qualifiers
        TSNode typeChild = TreeSitterParser.getChildByFieldName(node, "type");
        if (TreeSitterParser.isValid(typeChild))
            return mapCType(typeChild);

        // Walk children for the type specifier
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "primitive_type" || childType == "sized_type_specifier"
                    || childType == "struct_specifier" || childType == "type_identifier"
                    || childType == "enum_specifier")
                return mapCType(child);
        }
        return new BasicType(loc, BasicType.Kind.Int32);
    }

    // ------------------------------------------------------------------
    // Statements
    // ------------------------------------------------------------------

    private Statement parseStatement(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        string nodeType = TreeSitterParser.getNodeType(node);

        switch (nodeType) {
        case "compound_statement":
            return parseCompoundStatement(node);

        case "return_statement":
            return parseReturnStatement(node, loc);

        case "if_statement":
            return parseIfStatement(node, loc);

        case "for_statement":
            return parseForStatement(node, loc);

        case "while_statement":
            return parseWhileStatement(node, loc);

        case "expression_statement":
            return parseExpressionStatement(node, loc);

        case "declaration":
            return parseLocalDeclaration(node, loc);

        case "break_statement":
            return new BreakStatement(loc);

        case "continue_statement":
            return new ContinueStatement(loc);

        case "comment":
        case ";":
            return null;

        default:
            log(2, "C bridge: skipping statement type: ", nodeType);
            return null;
        }
    }

    private CompoundStatement parseCompoundStatement(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        Statement[] stmts;

        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);

            if (childType == "{" || childType == "}" || childType == "comment")
                continue;

            auto stmt = parseStatement(child);
            if (stmt !is null)
                stmts ~= stmt;
        }

        return new CompoundStatement(loc, stmts);
    }

    private Statement parseReturnStatement(TSNode node, SourceLocation loc) {
        // return_statement children: "return" [expression] ";"
        Expression value;
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType != "return" && childType != ";") {
                value = parseExpression(child);
                break;
            }
        }
        return new ReturnStatement(loc, value);
    }

    private Statement parseIfStatement(TSNode node, SourceLocation loc) {
        TSNode condNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode thenNode = TreeSitterParser.getChildByFieldName(node, "consequence");
        TSNode elseNode = TreeSitterParser.getChildByFieldName(node, "alternative");

        Expression cond = TreeSitterParser.isValid(condNode)
            ? parseExpression(condNode) : null;

        // Unwrap parenthesized_expression around condition
        // (tree-sitter-c includes the parens in the condition node)

        Statement thenStmt = TreeSitterParser.isValid(thenNode)
            ? parseStatement(thenNode) : null;

        Statement elseStmt;
        if (TreeSitterParser.isValid(elseNode)) {
            // else_clause wraps the actual statement
            uint childCount = TreeSitterParser.getChildCount(elseNode);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(elseNode, i);
                string childType = TreeSitterParser.getNodeType(child);
                if (childType != "else") {
                    elseStmt = parseStatement(child);
                    break;
                }
            }
        }

        return new IfStatement(loc, cond, thenStmt, elseStmt);
    }

    private Statement parseForStatement(TSNode node, SourceLocation loc) {
        TSNode initNode = TreeSitterParser.getChildByFieldName(node, "initializer");
        TSNode condNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode updateNode = TreeSitterParser.getChildByFieldName(node, "update");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");

        Statement init_;
        if (TreeSitterParser.isValid(initNode)) {
            string initType = TreeSitterParser.getNodeType(initNode);
            if (initType == "declaration")
                init_ = parseLocalDeclaration(initNode, makeSourceLocation(initNode));
            else
                init_ = new ExpressionStatement(makeSourceLocation(initNode), parseExpression(initNode));
        }

        Expression cond = TreeSitterParser.isValid(condNode)
            ? parseExpression(condNode) : null;

        Expression update = TreeSitterParser.isValid(updateNode)
            ? parseExpression(updateNode) : null;

        Statement body_ = TreeSitterParser.isValid(bodyNode)
            ? parseStatement(bodyNode) : null;

        return new ForStatement(loc, init_, cond, update, body_);
    }

    private Statement parseWhileStatement(TSNode node, SourceLocation loc) {
        TSNode condNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");

        Expression cond = TreeSitterParser.isValid(condNode)
            ? parseExpression(condNode) : null;

        Statement body_ = TreeSitterParser.isValid(bodyNode)
            ? parseStatement(bodyNode) : null;

        return new WhileStatement(loc, cond, body_);
    }

    private Statement parseExpressionStatement(TSNode node, SourceLocation loc) {
        // expression_statement children: expression ";"
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType != ";") {
                auto expr = parseExpression(child);
                return new ExpressionStatement(loc, expr);
            }
        }
        return null;
    }

    private Statement parseLocalDeclaration(TSNode node, SourceLocation loc) {
        // Local variable: type declarator ;
        TSNode typeNode = TreeSitterParser.getChildByFieldName(node, "type");
        TSNode declNode = TreeSitterParser.getChildByFieldName(node, "declarator");

        if (!TreeSitterParser.isValid(typeNode))
            return null;

        Type baseType = mapCType(typeNode);

        if (!TreeSitterParser.isValid(declNode))
            return null;

        string declType = TreeSitterParser.getNodeType(declNode);

        if (declType == "init_declarator") {
            TSNode nameNode = TreeSitterParser.getChildByFieldName(declNode, "declarator");
            TSNode valueNode = TreeSitterParser.getChildByFieldName(declNode, "value");

            Type varType = baseType;
            string name;
            if (TreeSitterParser.isValid(nameNode)) {
                string nameNodeType = TreeSitterParser.getNodeType(nameNode);
                if (nameNodeType == "pointer_declarator") {
                    varType = new PointerType(loc, baseType);
                    name = extractIdentifierFromDeclarator(nameNode);
                } else {
                    name = TreeSitterParser.getNodeText(nameNode, sourceText);
                }
            }

            Expression init_ = TreeSitterParser.isValid(valueNode)
                ? parseExpression(valueNode) : null;

            return new VariableDeclarationStatement(loc, name, varType, init_);
        }

        if (declType == "identifier") {
            string name = TreeSitterParser.getNodeText(declNode, sourceText);
            return new VariableDeclarationStatement(loc, name, baseType, null);
        }

        if (declType == "pointer_declarator") {
            Type varType = new PointerType(loc, baseType);
            string name = extractIdentifierFromDeclarator(declNode);
            return new VariableDeclarationStatement(loc, name, varType, null);
        }

        return null;
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    private Expression parseExpression(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        string nodeType = TreeSitterParser.getNodeType(node);

        switch (nodeType) {
        case "binary_expression":
            return parseBinaryExpression(node, loc);

        case "assignment_expression":
            return parseAssignmentExpression(node, loc);

        case "call_expression":
            return parseCallExpression(node, loc);

        case "identifier":
            return new IdentifierExpression(loc, TreeSitterParser.getNodeText(node, sourceText));

        case "number_literal":
            return parseNumberLiteral(node, loc);

        case "string_literal":
            return parseStringLiteral(node, loc);

        case "char_literal":
            return parseCharLiteral(node, loc);

        case "true":
            return LiteralExpression.boolean(loc, true);

        case "false":
            return LiteralExpression.boolean(loc, false);

        case "null":
            return LiteralExpression.null_(loc);

        case "field_expression":
            return parseFieldExpression(node, loc);

        case "unary_expression":
            return parseUnaryExpression(node, loc);

        case "update_expression":
            return parseUpdateExpression(node, loc);

        case "cast_expression":
            return parseCastExpression(node, loc);

        case "parenthesized_expression":
            return parseParenthesizedExpression(node, loc);

        case "subscript_expression":
            return parseSubscriptExpression(node, loc);

        case "conditional_expression":
            return parseConditionalExpression(node, loc);

        case "sizeof_expression":
            return parseSizeofExpression(node, loc);

        case "compound_literal_expression":
            // Skip compound literals for now
            throw new ParseError("Compound literals not supported", loc);

        default:
            throw new ParseError("Unknown C expression node: " ~ nodeType, loc);
        }
    }

    private Expression parseBinaryExpression(TSNode node, SourceLocation loc) {
        TSNode leftNode = TreeSitterParser.getChildByFieldName(node, "left");
        TSNode rightNode = TreeSitterParser.getChildByFieldName(node, "right");

        if (!TreeSitterParser.isValid(leftNode) || !TreeSitterParser.isValid(rightNode)) {
            // Fallback: positional children [left, op, right]
            if (TreeSitterParser.getChildCount(node) >= 3) {
                leftNode = TreeSitterParser.getChild(node, 0);
                rightNode = TreeSitterParser.getChild(node, 2);
            } else {
                throw new ParseError("Binary expression missing operands", loc);
            }
        }

        Expression left = parseExpression(leftNode);
        Expression right = parseExpression(rightNode);

        // Find operator text (anonymous child between left and right)
        string opText;
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            // Operator nodes are anonymous (not named types)
            if (childType == "+" || childType == "-" || childType == "*"
                    || childType == "/" || childType == "%"
                    || childType == "==" || childType == "!="
                    || childType == "<" || childType == "<="
                    || childType == ">" || childType == ">="
                    || childType == "&&" || childType == "||"
                    || childType == "&" || childType == "|"
                    || childType == "^" || childType == "<<"
                    || childType == ">>") {
                opText = childType;
                break;
            }
        }

        if (opText.length == 0) {
            // Try extracting from source text between operands
            uint leftEnd = ts_node_end_byte(leftNode);
            uint rightStart = ts_node_start_byte(rightNode);
            if (leftEnd < rightStart && leftEnd < sourceText.length && rightStart <= sourceText.length)
                opText = sourceText[leftEnd .. rightStart].strip();
        }

        auto op = mapBinaryOperator(opText, loc);
        return new BinaryExpression(loc, left, op, right);
    }

    private BinaryExpression.Operator mapBinaryOperator(string opText, SourceLocation loc) {
        switch (opText) {
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
        default:
            throw new ParseError("Unknown C binary operator: " ~ opText, loc);
        }
    }

    private Expression parseAssignmentExpression(TSNode node, SourceLocation loc) {
        TSNode leftNode = TreeSitterParser.getChildByFieldName(node, "left");
        TSNode rightNode = TreeSitterParser.getChildByFieldName(node, "right");

        if (!TreeSitterParser.isValid(leftNode) || !TreeSitterParser.isValid(rightNode))
            throw new ParseError("Assignment expression missing operands", loc);

        Expression left = parseExpression(leftNode);
        Expression right = parseExpression(rightNode);

        // Find operator text
        string opText = "=";
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "=" || childType == "+=" || childType == "-="
                    || childType == "*=" || childType == "/="
                    || childType == "%=" || childType == "&="
                    || childType == "|=" || childType == "^="
                    || childType == "<<=" || childType == ">>=") {
                opText = childType;
                break;
            }
        }

        auto op = mapAssignmentOperator(opText);
        return new AssignmentExpression(loc, left, op, right);
    }

    private AssignmentExpression.Operator mapAssignmentOperator(string opText) {
        switch (opText) {
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
        default: return AssignmentExpression.Operator.Assign;
        }
    }

    private Expression parseCallExpression(TSNode node, SourceLocation loc) {
        TSNode funcNode = TreeSitterParser.getChildByFieldName(node, "function");
        TSNode argsNode = TreeSitterParser.getChildByFieldName(node, "arguments");

        if (!TreeSitterParser.isValid(funcNode))
            throw new ParseError("Call expression missing function", loc);

        Expression func = parseExpression(funcNode);
        Expression[] args;

        if (TreeSitterParser.isValid(argsNode)) {
            // argument_list children: "(" [expr] "," [expr] ... ")"
            uint childCount = TreeSitterParser.getChildCount(argsNode);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(argsNode, i);
                string childType = TreeSitterParser.getNodeType(child);
                if (childType != "(" && childType != ")" && childType != ",") {
                    args ~= parseExpression(child);
                }
            }
        }

        return new CallExpression(loc, func, args);
    }

    private Expression parseFieldExpression(TSNode node, SourceLocation loc) {
        TSNode argNode = TreeSitterParser.getChildByFieldName(node, "argument");
        TSNode fieldNode = TreeSitterParser.getChildByFieldName(node, "field");

        if (!TreeSitterParser.isValid(argNode) || !TreeSitterParser.isValid(fieldNode))
            throw new ParseError("Field expression missing argument or field", loc);

        Expression obj = parseExpression(argNode);
        string fieldName = TreeSitterParser.getNodeText(fieldNode, sourceText);

        // Check if this is -> (pointer dereference) or . (direct access)
        // The operator is an anonymous child between argument and field
        bool isArrow = false;
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "->") {
                isArrow = true;
                break;
            }
        }

        if (isArrow) {
            // Desugar p->field to (*p).field
            auto deref = new UnaryExpression(loc, UnaryExpression.Operator.Dereference, obj);
            return new MemberExpression(loc, deref, fieldName);
        }

        return new MemberExpression(loc, obj, fieldName);
    }

    private Expression parseUnaryExpression(TSNode node, SourceLocation loc) {
        TSNode argNode = TreeSitterParser.getChildByFieldName(node, "argument");
        if (!TreeSitterParser.isValid(argNode)) {
            // Fallback: last child is the operand
            uint childCount = TreeSitterParser.getChildCount(node);
            if (childCount >= 2)
                argNode = TreeSitterParser.getChild(node, childCount - 1);
            else
                throw new ParseError("Unary expression missing operand", loc);
        }

        Expression operand = parseExpression(argNode);

        // Find operator: first child that's an operator token
        string opText;
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "-" || childType == "+" || childType == "!"
                    || childType == "~" || childType == "*"
                    || childType == "&") {
                opText = childType;
                break;
            }
        }

        switch (opText) {
        case "-": return new UnaryExpression(loc, UnaryExpression.Operator.Minus, operand);
        case "+": return new UnaryExpression(loc, UnaryExpression.Operator.Plus, operand);
        case "!": return new UnaryExpression(loc, UnaryExpression.Operator.LogicalNot, operand);
        case "~": return new UnaryExpression(loc, UnaryExpression.Operator.BitwiseNot, operand);
        case "*": return new UnaryExpression(loc, UnaryExpression.Operator.Dereference, operand);
        case "&": return new UnaryExpression(loc, UnaryExpression.Operator.AddressOf, operand);
        default:
            throw new ParseError("Unknown C unary operator: " ~ opText, loc);
        }
    }

    private Expression parseUpdateExpression(TSNode node, SourceLocation loc) {
        // Desugar x++ → x = x + 1, x-- → x = x - 1
        TSNode argNode = TreeSitterParser.getChildByFieldName(node, "argument");
        if (!TreeSitterParser.isValid(argNode))
            throw new ParseError("Update expression missing argument", loc);

        Expression operand = parseExpression(argNode);

        // Determine if it's ++ or --
        string text = TreeSitterParser.getNodeText(node, sourceText);
        auto one = LiteralExpression.integer(loc, 1);

        if (text.canFind("++")) {
            return new AssignmentExpression(loc, operand,
                    AssignmentExpression.Operator.AddAssign, one);
        } else {
            return new AssignmentExpression(loc, operand,
                    AssignmentExpression.Operator.SubtractAssign, one);
        }
    }

    private Expression parseCastExpression(TSNode node, SourceLocation loc) {
        TSNode typeNode = TreeSitterParser.getChildByFieldName(node, "type");
        TSNode valueNode = TreeSitterParser.getChildByFieldName(node, "value");

        if (!TreeSitterParser.isValid(typeNode) || !TreeSitterParser.isValid(valueNode))
            throw new ParseError("Cast expression missing type or value", loc);

        Type targetType = mapCType(typeNode);
        Expression value = parseExpression(valueNode);
        return new CastExpression(loc, targetType, value);
    }

    private Expression parseParenthesizedExpression(TSNode node, SourceLocation loc) {
        // Unwrap: skip "(" and ")" children
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType != "(" && childType != ")") {
                return parseExpression(child);
            }
        }
        throw new ParseError("Empty parenthesized expression", loc);
    }

    private Expression parseSubscriptExpression(TSNode node, SourceLocation loc) {
        // array[index]
        TSNode argNode = TreeSitterParser.getChildByFieldName(node, "argument");
        TSNode indexNode = TreeSitterParser.getChildByFieldName(node, "index");

        if (!TreeSitterParser.isValid(argNode) || !TreeSitterParser.isValid(indexNode))
            throw new ParseError("Subscript expression missing argument or index", loc);

        Expression arr = parseExpression(argNode);
        Expression index = parseExpression(indexNode);
        return new IndexExpression(loc, arr, index);
    }

    private Expression parseConditionalExpression(TSNode node, SourceLocation loc) {
        // C ternary: cond ? then : else
        // Desugar to if-expression is not available, so expand inline.
        // For now, skip this and throw — it's rarely needed for simple C code.
        TSNode condNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode consNode = TreeSitterParser.getChildByFieldName(node, "consequence");
        TSNode altNode = TreeSitterParser.getChildByFieldName(node, "alternative");

        if (!TreeSitterParser.isValid(condNode) || !TreeSitterParser.isValid(consNode)
                || !TreeSitterParser.isValid(altNode))
            throw new ParseError("Conditional expression missing operands", loc);

        // No TernaryExpression in AST — skip for first iteration
        throw new ParseError("C ternary operator not yet supported", loc);
    }

    private Expression parseSizeofExpression(TSNode node, SourceLocation loc) {
        // sizeof(type) or sizeof(expr) — return as integer literal
        // For first iteration, skip
        throw new ParseError("sizeof not yet supported", loc);
    }

    private Expression parseNumberLiteral(TSNode node, SourceLocation loc) {
        import std.conv : parse;
        string text = TreeSitterParser.getNodeText(node, sourceText);

        // Strip suffixes: u, U, l, L, ll, LL, f, F, etc.
        string clean = text;
        while (clean.length > 0) {
            char last = clean[$ - 1];
            if (last == 'u' || last == 'U' || last == 'l' || last == 'L'
                    || last == 'f' || last == 'F')
                clean = clean[0 .. $ - 1];
            else
                break;
        }

        // Floating point?
        if (clean.canFind('.') || (clean.canFind('e') && !clean.startsWith("0x"))
                || clean.canFind('E')) {
            try {
                double val = to!double(clean);
                return LiteralExpression.floating(loc, val);
            } catch (Exception) {
                return LiteralExpression.integer(loc, 0);
            }
        }

        // Integer
        try {
            long val;
            if (clean.startsWith("0x") || clean.startsWith("0X")) {
                string digits = clean[2 .. $];
                val = parse!long(digits, 16);
            } else if (clean.startsWith("0") && clean.length > 1 && !clean.startsWith("0x")) {
                // C octal: leading 0
                string digits = clean[1 .. $];
                if (digits.length > 0)
                    val = parse!long(digits, 8);
            } else {
                val = to!long(clean);
            }
            return LiteralExpression.integer(loc, val);
        } catch (Exception) {
            return LiteralExpression.integer(loc, 0);
        }
    }

    private Expression parseStringLiteral(TSNode node, SourceLocation loc) {
        string text = TreeSitterParser.getNodeText(node, sourceText);
        // Remove surrounding quotes
        if (text.length >= 2 && text[0] == '"' && text[$ - 1] == '"')
            text = text[1 .. $ - 1];
        // Basic C escape processing
        text = unescapeCString(text);
        return LiteralExpression.string_(loc, text);
    }

    private Expression parseCharLiteral(TSNode node, SourceLocation loc) {
        string text = TreeSitterParser.getNodeText(node, sourceText);
        // Remove surrounding quotes
        if (text.length >= 2 && text[0] == '\'' && text[$ - 1] == '\'')
            text = text[1 .. $ - 1];
        // Unescape
        text = unescapeCString(text);
        if (text.length > 0)
            return LiteralExpression.char_(loc, text[0]);
        return LiteralExpression.integer(loc, 0);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private SourceLocation makeSourceLocation(TSNode node) {
        auto startPoint = TreeSitterParser.getStartPoint(node);
        return SourceLocation(
                filename,
                startPoint.row + 1, // tree-sitter is 0-based
                startPoint.column + 1,
                ts_node_start_byte(node),
                ts_node_end_byte(node));
    }

    /**
     * Extract name and parameters from a function_declarator node.
     */
    private void extractFunctionDeclarator(TSNode node, Type baseReturnType,
            out string name, out Parameter[] params, out bool isPointerReturn) {
        isPointerReturn = false;
        string nodeType = TreeSitterParser.getNodeType(node);

        if (nodeType == "pointer_declarator") {
            isPointerReturn = true;
            uint count = TreeSitterParser.getChildCount(node);
            for (uint i = 0; i < count; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                if (TreeSitterParser.getNodeType(child) == "function_declarator") {
                    node = child;
                    break;
                }
            }
        }

        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "declarator");
        TSNode paramsNode = TreeSitterParser.getChildByFieldName(node, "parameters");

        if (TreeSitterParser.isValid(nameNode)) {
            string nameNodeType = TreeSitterParser.getNodeType(nameNode);
            if (nameNodeType == "identifier" || nameNodeType == "field_identifier")
                name = TreeSitterParser.getNodeText(nameNode, sourceText);
            else if (nameNodeType == "pointer_declarator") {
                isPointerReturn = true;
                name = extractIdentifierFromDeclarator(nameNode);
            } else
                name = TreeSitterParser.getNodeText(nameNode, sourceText);
        }

        params = [];
        if (TreeSitterParser.isValid(paramsNode)) {
            uint childCount = TreeSitterParser.getChildCount(paramsNode);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(paramsNode, i);
                if (TreeSitterParser.getNodeType(child) == "parameter_declaration") {
                    auto p = parseParameterDeclaration(child);
                    if (p.type !is null)
                        params ~= p;
                }
            }
        }
    }

    private Parameter parseParameterDeclaration(TSNode node) {
        TSNode typeNode = TreeSitterParser.getChildByFieldName(node, "type");
        TSNode declNode = TreeSitterParser.getChildByFieldName(node, "declarator");

        if (!TreeSitterParser.isValid(typeNode))
            return Parameter(null, "");

        Type paramType = mapCType(typeNode);

        // Check for void parameter (C style: void foo(void))
        if (auto bt = cast(BasicType) paramType) {
            if (bt.kind == BasicType.Kind.Void && !TreeSitterParser.isValid(declNode))
                return Parameter(null, ""); // Skip void parameter
        }

        string name = "";
        if (TreeSitterParser.isValid(declNode)) {
            string declType = TreeSitterParser.getNodeType(declNode);
            if (declType == "pointer_declarator") {
                paramType = new PointerType(makeSourceLocation(node), paramType);
                name = extractIdentifierFromDeclarator(declNode);
            } else if (declType == "array_declarator") {
                // C array params decay to pointers
                paramType = new PointerType(makeSourceLocation(node), paramType);
                name = extractIdentifierFromDeclarator(declNode);
            } else {
                name = TreeSitterParser.getNodeText(declNode, sourceText);
            }
        }

        return Parameter(paramType, name);
    }

    /**
     * Walk down a declarator tree to find the innermost identifier.
     */
    private string extractIdentifierFromDeclarator(TSNode node) {
        string nodeType = TreeSitterParser.getNodeType(node);
        if (nodeType == "identifier" || nodeType == "field_identifier"
                || nodeType == "type_identifier")
            return TreeSitterParser.getNodeText(node, sourceText);

        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "identifier" || childType == "field_identifier"
                    || childType == "type_identifier")
                return TreeSitterParser.getNodeText(child, sourceText);
            // Recurse into nested declarators
            if (childType == "pointer_declarator" || childType == "array_declarator"
                    || childType == "function_declarator"
                    || childType == "parenthesized_declarator") {
                string result = extractIdentifierFromDeclarator(child);
                if (result.length > 0)
                    return result;
            }
        }
        return "";
    }

    /**
     * Find the innermost identifier node in a declarator (returns TSNode).
     */
    private TSNode findInnerIdentifier(TSNode node) {
        string nodeType = TreeSitterParser.getNodeType(node);
        if (nodeType == "identifier" || nodeType == "field_identifier"
                || nodeType == "type_identifier")
            return node;

        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "identifier" || childType == "field_identifier"
                    || childType == "type_identifier")
                return child;
            if (childType == "pointer_declarator" || childType == "array_declarator"
                    || childType == "function_declarator") {
                TSNode result = findInnerIdentifier(child);
                if (TreeSitterParser.isValid(result))
                    return result;
            }
        }
        return node; // fallback
    }

    /**
     * Basic C string escape processing.
     */
    private static string unescapeCString(string s) {
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
                case 'a': result ~= '\a'; break;
                case 'b': result ~= '\b'; break;
                case 'f': result ~= '\f'; break;
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
}

// Re-import ParseError from the D bridge
import parser.tree_sitter_bridge : ParseError;

// ------------------------------------------------------------------
// Unit tests
// ------------------------------------------------------------------

unittest {
    // Parse a simple C function
    auto bridge = new CTreeSitterBridge("test.c",
            "int add(int a, int b) { return a + b; }");
    auto decls = bridge.parseSourceFile();
    assert(decls.length == 1, "Expected 1 declaration, got " ~ to!string(decls.length));
    auto func = cast(FunctionDecl) decls[0];
    assert(func !is null, "Expected FunctionDecl");
    assert(func.name == "add", "Expected function name 'add', got '" ~ func.name ~ "'");
    assert(func.parameters.length == 2, "Expected 2 parameters");
    assert(func.parameters[0].name == "a");
    assert(func.parameters[1].name == "b");
    assert(func.body_ !is null, "Expected function body");
}

unittest {
    // Parse a C struct
    auto bridge = new CTreeSitterBridge("test.c",
            "struct Point { int x; int y; };");
    auto decls = bridge.parseSourceFile();
    assert(decls.length == 1, "Expected 1 declaration, got " ~ to!string(decls.length));
    auto sd = cast(StructDecl) decls[0];
    assert(sd !is null, "Expected StructDecl");
    assert(sd.name == "Point");
    assert(sd.members.length == 2);
}

unittest {
    // Parse C enum
    auto bridge = new CTreeSitterBridge("test.c",
            "enum Color { RED, GREEN = 2, BLUE };");
    auto decls = bridge.parseSourceFile();
    assert(decls.length == 3, "Expected 3 manifest constants, got " ~ to!string(decls.length));
    auto red = cast(ManifestConstantDecl) decls[0];
    assert(red !is null);
    assert(red.name == "RED");
    auto green = cast(ManifestConstantDecl) decls[1];
    assert(green !is null);
    assert(green.name == "GREEN");
    auto blue = cast(ManifestConstantDecl) decls[2];
    assert(blue !is null);
    assert(blue.name == "BLUE");
}

unittest {
    // Parse forward declaration
    auto bridge = new CTreeSitterBridge("test.c",
            "void foo(int x);");
    auto decls = bridge.parseSourceFile();
    assert(decls.length == 1, "Expected 1 declaration, got " ~ to!string(decls.length));
    auto func = cast(FunctionDecl) decls[0];
    assert(func !is null, "Expected FunctionDecl");
    assert(func.name == "foo");
    assert(func.body_ is null, "Expected no body (forward declaration)");
}

unittest {
    // Parse global variable
    auto bridge = new CTreeSitterBridge("test.c",
            "int global_var = 42;");
    auto decls = bridge.parseSourceFile();
    assert(decls.length == 1, "Expected 1 declaration, got " ~ to!string(decls.length));
    auto vd = cast(VariableDecl) decls[0];
    assert(vd !is null, "Expected VariableDecl");
    assert(vd.name == "global_var");
}

unittest {
    // Parse void function with void parameter
    auto bridge = new CTreeSitterBridge("test.c",
            "void doNothing(void) { }");
    auto decls = bridge.parseSourceFile();
    assert(decls.length == 1);
    auto func = cast(FunctionDecl) decls[0];
    assert(func !is null);
    assert(func.name == "doNothing");
    assert(func.parameters.length == 0, "void param should be stripped");
}

unittest {
    // Parse function with if/else
    auto bridge = new CTreeSitterBridge("test.c",
            "int abs(int x) { if (x < 0) { return -x; } else { return x; } }");
    auto decls = bridge.parseSourceFile();
    assert(decls.length == 1);
    auto func = cast(FunctionDecl) decls[0];
    assert(func !is null);
    assert(func.name == "abs");
    auto body_ = cast(CompoundStatement) func.body_;
    assert(body_ !is null);
    assert(body_.statements.length == 1); // single if statement
    auto ifStmt = cast(IfStatement) body_.statements[0];
    assert(ifStmt !is null);
    assert(ifStmt.elseStatement !is null, "Expected else clause");
}

unittest {
    // Parse empty source
    auto bridge = new CTreeSitterBridge("empty.c", "");
    auto decls = bridge.parseSourceFile();
    assert(decls.length == 0);
}

unittest {
    // Parse function with for loop
    auto bridge = new CTreeSitterBridge("test.c",
            "int sum(int n) { int s = 0; for (int i = 0; i < n; i++) { s = s + i; } return s; }");
    auto decls = bridge.parseSourceFile();
    assert(decls.length == 1);
    auto func = cast(FunctionDecl) decls[0];
    assert(func !is null);
    assert(func.name == "sum");
}

unittest {
    // Parse static function (private visibility)
    auto bridge = new CTreeSitterBridge("test.c",
            "static int helper(int x) { return x * 2; }");
    auto decls = bridge.parseSourceFile();
    assert(decls.length == 1);
    auto func = cast(FunctionDecl) decls[0];
    assert(func !is null);
    assert(func.visibility == Visibility.private_, "static → private");
}

unittest {
    // Parse multiple declarations
    auto bridge = new CTreeSitterBridge("test.c",
            "int add(int a, int b) { return a + b; }\n" ~
            "int mul(int a, int b) { return a * b; }");
    auto decls = bridge.parseSourceFile();
    assert(decls.length == 2, "Expected 2 declarations, got " ~ to!string(decls.length));
}
