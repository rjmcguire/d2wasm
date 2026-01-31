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
        auto root = parser.parseString(sourceText);
        return parseSourceFileNode(root);
    }
    
    /**
     * Convert a tree-sitter parse tree root to our AST
     */
    Declaration[] parseSourceFileNode(TSNode root) {
        if (!TreeSitterParser.isValid(root)) {
            throw new ParseError("Invalid parse tree root", SourceLocation(filename, 1, 1, 0, 0));
        }
        
        if (TreeSitterParser.hasError(root)) {
            throw new ParseError("Parse errors in source file", SourceLocation(filename, 1, 1, 0, 0));
        }
        
        Declaration[] declarations;
        
        uint childCount = TreeSitterParser.getChildCount(root);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(root, i);
            string nodeType = TreeSitterParser.getNodeType(child);
            
            try {
                if (nodeType == "function_declaration") {
                    declarations ~= parseFunctionDeclaration(child);
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
                    // Skip comments and whitespace, but warn about unknown nodes
                    writeln("Warning: Skipping unknown top-level node: ", nodeType);
                }
            } catch (ParseError e) {
                writeln("Parse error in ", nodeType, ": ", e.msg);
                // Continue parsing other declarations
            }
        }
        
        return declarations;
    }
    
    /**
     * Convert function declaration node
     */
    FunctionDecl parseFunctionDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        // Extract components using real tree-sitter field access
        TSNode returnTypeNode = TreeSitterParser.getChildByFieldName(node, "return_type");
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        TSNode parametersNode = TreeSitterParser.getChildByFieldName(node, "parameters");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");
        
        if (!TreeSitterParser.isValid(nameNode)) {
            throw new ParseError("Function declaration missing name", loc);
        }
        
        string name = TreeSitterParser.getNodeText(nameNode, sourceText);
        if (name.length == 0) {
            name = nameNode.text;  // fallback to stored text
        }
        Type returnType = !TreeSitterParser.isValid(returnTypeNode) ? 
            new BasicType(loc, BasicType.Kind.Void) : 
            parseType(returnTypeNode);
        
        Parameter[] parameters;
        if (TreeSitterParser.isValid(parametersNode)) {
            parameters = parseParameterList(parametersNode);
        }
        
        Statement body_;
        if (TreeSitterParser.isValid(bodyNode)) {
            body_ = parseStatement(bodyNode);
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
        
        foreach (child; parametersNode.children) {
            if (child.nodeType == "parameter") {
                TSNode typeNode = TreeSitterParser.getChildByFieldName(*child, "type");
                TSNode nameNode = TreeSitterParser.getChildByFieldName(*child, "name");
                TSNode defaultNode = TreeSitterParser.getChildByFieldName(*child, "default_value");
                
                if (typeNode.isNull() || nameNode.isNull()) {
                    continue;  // Skip malformed parameters
                }
                
                Type paramType = parseType(typeNode);
                string paramName = nameNode.text;
                Expression defaultValue = defaultNode.isNull() ? null : parseExpression(defaultNode);
                
                parameters ~= Parameter(paramType, paramName, defaultValue);
            }
        }
        
        return parameters;
    }
    
    /**
     * Parse class declaration
     */
    ClassDecl parseClassDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        if (nameNode.isNull()) {
            throw new ParseError("Class declaration missing name", loc);
        }
        
        string name = nameNode.text;
        
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
        if (nameNode.isNull()) {
            throw new ParseError("Struct declaration missing name", loc);
        }
        
        string name = nameNode.text;
        
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
        if (nameNode.isNull()) {
            throw new ParseError("Interface declaration missing name", loc);
        }
        
        string name = nameNode.text;
        
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
        
        if (typeNode.isNull() || nameNode.isNull()) {
            throw new ParseError("Variable declaration missing type or name", loc);
        }
        
        Type varType = parseType(typeNode);
        string name = nameNode.text;
        Expression initializer = initNode.isNull() ? null : parseExpression(initNode);
        
        return new VariableDecl(loc, name, varType, initializer);
    }
    
    /**
     * Parse enum declaration
     */
    EnumDecl parseEnumDeclaration(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        if (nameNode.isNull()) {
            throw new ParseError("Enum declaration missing name", loc);
        }
        
        string name = nameNode.text;
        
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
        
        switch (node.nodeType) {
            case "basic_type":
                return parseBasicType(node, loc);
            case "array_type":
                return parseArrayType(node, loc);
            case "pointer_type":
                return parsePointerType(node, loc);
            case "identifier":
                return new UserType(loc, node.text);
            case "return_type":  // Mock parser creates this
                return parseBasicType(node, loc);
            default:
                // For mock parser, try to parse the text directly as a basic type
                return parseBasicTypeByText(node.text, loc);
        }
    }
    
    /**
     * Parse basic type by text content (for mock parser)
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
        string typeName = node.text;
        
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
        
        if (elementTypeNode.isNull()) {
            throw new ParseError("Array type missing element type", loc);
        }
        
        Type elementType = parseType(elementTypeNode);
        Expression size = sizeNode.isNull() ? null : parseExpression(sizeNode);
        
        return new ArrayType(loc, elementType, size);
    }
    
    /**
     * Parse pointer type
     */
    PointerType parsePointerType(TSNode node, SourceLocation loc) {
        TSNode pointeeTypeNode = TreeSitterParser.getChildByFieldName(node, "pointee_type");
        
        if (pointeeTypeNode.isNull()) {
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
        
        switch (node.nodeType) {
            case "compound_statement":
                return parseCompoundStatement(node, loc);
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
                throw new ParseError("Unknown statement node: " ~ node.nodeType, loc);
        }
    }
    
    /**
     * Parse compound statement
     */
    CompoundStatement parseCompoundStatement(TSNode node, SourceLocation loc) {
        Statement[] statements;
        
        foreach (child; node.children) {
            if (child.nodeType != "{" && child.nodeType != "}") {
                statements ~= parseStatement(*child);
            }
        }
        
        return new CompoundStatement(loc, statements);
    }
    
    /**
     * Parse if statement
     */
    IfStatement parseIfStatement(TSNode node, SourceLocation loc) {
        TSNode conditionNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode thenNode = TreeSitterParser.getChildByFieldName(node, "then_statement");
        TSNode elseNode = TreeSitterParser.getChildByFieldName(node, "else_statement");
        
        if (conditionNode.isNull() || thenNode.isNull()) {
            throw new ParseError("If statement missing condition or body", loc);
        }
        
        Expression condition = parseExpression(conditionNode);
        Statement thenStatement = parseStatement(thenNode);
        Statement elseStatement = elseNode.isNull() ? null : parseStatement(elseNode);
        
        return new IfStatement(loc, condition, thenStatement, elseStatement);
    }
    
    /**
     * Parse while statement
     */
    WhileStatement parseWhileStatement(TSNode node, SourceLocation loc) {
        TSNode conditionNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");
        
        if (conditionNode.isNull() || bodyNode.isNull()) {
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
        
        if (bodyNode.isNull()) {
            throw new ParseError("For statement missing body", loc);
        }
        
        Statement init = initNode.isNull() ? null : parseStatement(initNode);
        Expression condition = conditionNode.isNull() ? null : parseExpression(conditionNode);
        Expression update = updateNode.isNull() ? null : parseExpression(updateNode);
        Statement body_ = parseStatement(bodyNode);
        
        return new ForStatement(loc, init, condition, update, body_);
    }
    
    /**
     * Parse return statement
     */
    ReturnStatement parseReturnStatement(TSNode node, SourceLocation loc) {
        TSNode valueNode = TreeSitterParser.getChildByFieldName(node, "value");
        
        Expression value = valueNode.isNull() ? null : parseExpression(valueNode);
        return new ReturnStatement(loc, value);
    }
    
    /**
     * Parse expression statement
     */
    ExpressionStatement parseExpressionStatement(TSNode node, SourceLocation loc) {
        TSNode exprNode = TreeSitterParser.getChildByFieldName(node, "expression");
        
        if (exprNode.isNull()) {
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
        
        switch (node.nodeType) {
            case "binary_expression":
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
                return new IdentifierExpression(loc, node.text);
            case "integer_literal":
                return LiteralExpression.integer(loc, to!long(node.text));
            case "float_literal":
                return LiteralExpression.floating(loc, to!double(node.text));
            case "string_literal":
                return LiteralExpression.string_(loc, node.text[1..$-1]); // Remove quotes
            case "boolean_literal":
                return LiteralExpression.boolean(loc, node.text == "true");
            case "null_literal":
                return LiteralExpression.null_(loc);
            case "cast_expression":
                return parseCastExpression(node, loc);
            case "assignment_expression":
                return parseAssignmentExpression(node, loc);
            default:
                throw new ParseError("Unknown expression node: " ~ node.nodeType, loc);
        }
    }
    
    /**
     * Parse binary expression
     */
    BinaryExpression parseBinaryExpression(TSNode node, SourceLocation loc) {
        TSNode leftNode = TreeSitterParser.getChildByFieldName(node, "left");
        TSNode operatorNode = TreeSitterParser.getChildByFieldName(node, "operator");
        TSNode rightNode = TreeSitterParser.getChildByFieldName(node, "right");
        
        if (leftNode.isNull() || operatorNode.isNull() || rightNode.isNull()) {
            throw new ParseError("Binary expression missing operands or operator", loc);
        }
        
        Expression left = parseExpression(leftNode);
        Expression right = parseExpression(rightNode);
        BinaryExpression.Operator operator = parseBinaryOperator(operatorNode.text);
        
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
        // TODO: Implement full unary expression parsing
        throw new ParseError("Unary expressions not yet implemented", loc);
    }
    
    /**
     * Parse call expression (placeholder implementation)
     */
    CallExpression parseCallExpression(TSNode node, SourceLocation loc) {
        // TODO: Implement full call expression parsing
        throw new ParseError("Call expressions not yet implemented", loc);
    }
    
    /**
     * Parse index expression (placeholder implementation)
     */
    IndexExpression parseIndexExpression(TSNode node, SourceLocation loc) {
        // TODO: Implement full index expression parsing
        throw new ParseError("Index expressions not yet implemented", loc);
    }
    
    /**
     * Parse member expression (placeholder implementation)
     */
    MemberExpression parseMemberExpression(TSNode node, SourceLocation loc) {
        // TODO: Implement full member expression parsing
        throw new ParseError("Member expressions not yet implemented", loc);
    }
    
    /**
     * Parse cast expression (placeholder implementation)
     */
    CastExpression parseCastExpression(TSNode node, SourceLocation loc) {
        // TODO: Implement full cast expression parsing
        throw new ParseError("Cast expressions not yet implemented", loc);
    }
    
    /**
     * Parse assignment expression (placeholder implementation)
     */
    AssignmentExpression parseAssignmentExpression(TSNode node, SourceLocation loc) {
        // TODO: Implement full assignment expression parsing
        throw new ParseError("Assignment expressions not yet implemented", loc);
    }
    
    /**
     * Create source location from tree-sitter node
     */
    SourceLocation makeSourceLocation(TSNode node) {
        auto startPoint = TreeSitterParser.getStartPoint(node);
        auto endPoint = TreeSitterParser.getEndPoint(node);
        
        return SourceLocation(
            filename,
            startPoint.row + 1,  // tree-sitter uses 0-based rows
            startPoint.column + 1,  // tree-sitter uses 0-based columns
            node.startOffset,
            node.endOffset
        );
    }
}