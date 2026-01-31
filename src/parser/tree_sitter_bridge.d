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
     */
    FunctionDecl parseFunctionDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        // Parse function declaration by examining children in order:
        // 1. type (return type)
        // 2. identifier (function name) 
        // 3. parameters
        // 4. function_body
        
        TSNode returnTypeNode, nameNode, parametersNode, bodyNode;
        
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            
            if (nodeType == "type" && !TreeSitterParser.isValid(returnTypeNode)) {
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
        
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        if (!TreeSitterParser.isValid(nameNode)) {
            throw new ParseError("Struct declaration missing name", loc);
        }
        
        string name = TreeSitterParser.getNodeText(nameNode, sourceText);
        
        // TODO: Parse struct members
        Declaration[] members;
        
        return new StructDecl(loc, name, members);
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
     */
    VariableDecl parseVariableDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        TSNode typeNode = TreeSitterParser.getChildByFieldName(node, "type");
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        TSNode initNode = TreeSitterParser.getChildByFieldName(node, "initializer");
        
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
     * Parse type from tree-sitter node
     */
    Type parseType(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        string nodeType = TreeSitterParser.getNodeType(node);
        
        // Handle different type node structures
        if (nodeType == "type") {
            // Look for the actual type inside the type node
            uint childCount = TreeSitterParser.getChildCount(node);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                return parseType(child);
            }
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
                return parseBlockStatement(node);
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
            default:
                throw new ParseError("Unknown statement node: " ~ nodeType, loc);
        }
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
        TSNode conditionNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode updateNode = TreeSitterParser.getChildByFieldName(node, "update");
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
            throw new ParseError("Expression statement missing expression", loc);
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
            case "binary_expression":
            case "add_expression":
            case "mul_expression":
            case "rel_expression":
            case "equal_expression":
            case "and_expression":
            case "or_expression":
                return parseBinaryExpression(node, loc);
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
                return LiteralExpression.string_(loc, text[1..$-1]); // Remove quotes
            }
            case "bool_literal":
            case "true":
            case "false": {
                string text = TreeSitterParser.getNodeText(node, sourceText);
                return LiteralExpression.boolean(loc, text == "true");
            }
            case "null_literal":
                return LiteralExpression.null_(loc);
            case "cast_expression":
                return parseCastExpression(node, loc);
            case "assignment_expression":
                return parseAssignmentExpression(node, loc);
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
        
        Expression function_ = parseExpression(functionNode);
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
                        arguments ~= parseExpression(child);
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
     * Parse assignment expression (placeholder implementation)
     */
    AssignmentExpression parseAssignmentExpression(TSNode node, SourceLocation loc) {
        TSNode leftNode = TreeSitterParser.getChildByFieldName(node, "left");
        TSNode operatorNode = TreeSitterParser.getChildByFieldName(node, "operator");
        TSNode rightNode = TreeSitterParser.getChildByFieldName(node, "right");
        
        if (!TreeSitterParser.isValid(leftNode) || !TreeSitterParser.isValid(operatorNode) || !TreeSitterParser.isValid(rightNode)) {
            throw new ParseError("Assignment expression missing operands or operator", loc);
        }
        
        Expression left = parseExpression(leftNode);
        Expression right = parseExpression(rightNode);
        AssignmentExpression.Operator op = parseAssignmentOperator(TreeSitterParser.getNodeText(operatorNode, sourceText));
        
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