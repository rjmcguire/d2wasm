/**
 * Tree-sitter bridge for JavaScript source files (importJS support).
 *
 * Maps tree-sitter-javascript parse tree nodes to the existing D AST types.
 * Handles: functions, variable declarations (var/let/const),
 * and function bodies (arithmetic, control flow, calls, member access).
 *
 * JavaScript is dynamically typed — all function params and returns default
 * to int (i32) for WASM compilation.  Variable declarations with initializers
 * use null type so the D type checker can auto-infer.
 */
module parser.js_tree_sitter_bridge;

import ast.nodes;
import ast.statements;
import ast.expressions;
import parser.tree_sitter_c;
import std.string;
import std.conv;
import std.algorithm;
import std.array : split;
import diagnostic.log : log;

// Re-import ParseError from the D bridge
import parser.tree_sitter_bridge : ParseError;

/**
 * Bridge that converts a tree-sitter-javascript parse tree into AST declarations.
 */
class JSTreeSitterBridge {
    string filename;
    string sourceText;
    TreeSitterParser parser;

    this(string filename, string sourceText) {
        this.filename = filename;
        this.sourceText = sourceText;
        this.parser = new TreeSitterParser(tree_sitter_javascript());
    }

    // ------------------------------------------------------------------
    // Top-level entry point
    // ------------------------------------------------------------------

    Declaration[] parseSourceFile() {
        auto root = parser.parseString(sourceText);
        if (!TreeSitterParser.isValid(root))
            throw new ParseError("Invalid parse tree root",
                SourceLocation(filename, 1, 1, 0, 0));
        return parseProgram(root);
    }

    // ------------------------------------------------------------------
    // Program (root node)
    // ------------------------------------------------------------------

    private Declaration[] parseProgram(TSNode root) {
        Declaration[] declarations;

        uint childCount = TreeSitterParser.getChildCount(root);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(root, i);
            string nodeType = TreeSitterParser.getNodeType(child);

            // Skip comments and empty statements
            if (nodeType == "comment" || nodeType == "empty_statement"
                    || nodeType == "hash_bang_line" || nodeType.length == 0)
                continue;

            try {
                auto decls = parseTopLevel(child);
                declarations ~= decls;
            } catch (ParseError e) {
                log(2, "JS parse error in ", nodeType, ": ", e.msg);
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
        case "function_declaration":
            return [parseFunctionDeclaration(node, loc)];

        case "variable_declaration":
        case "lexical_declaration":
            return parseVariableDeclarations(node, loc);

        case "class_declaration":
            return [parseClassDeclaration(node, loc)];

        case "export_statement":
            // Unwrap: export function foo() {...} → function_declaration
            return parseExportStatement(node, loc);

        case "expression_statement":
            // Top-level expression statements are skipped as declarations
            return [];

        default:
            log(2, "  Warning: Unknown JS top-level node type: ", nodeType);
            return [];
        }
    }

    // ------------------------------------------------------------------
    // Function declaration
    // ------------------------------------------------------------------

    private Declaration parseFunctionDeclaration(TSNode node, SourceLocation loc) {
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        TSNode paramsNode = TreeSitterParser.getChildByFieldName(node, "parameters");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");

        if (!TreeSitterParser.isValid(nameNode))
            throw new ParseError("JS function declaration missing name", loc);

        string name = TreeSitterParser.getNodeText(nameNode, sourceText);
        Parameter[] parameters = parseFormalParameters(paramsNode);

        Statement body_;
        if (TreeSitterParser.isValid(bodyNode))
            body_ = parseStatementBlock(bodyNode);
        else
            body_ = null;

        auto returnType = defaultType(loc);
        auto funcDecl = new FunctionDecl(loc, name, returnType, parameters, body_);
        return funcDecl;
    }

    // ------------------------------------------------------------------
    // Variable declarations (var/let/const)
    // ------------------------------------------------------------------

    private Declaration[] parseVariableDeclarations(TSNode node, SourceLocation loc) {
        Declaration[] result;

        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);

            if (childType == "variable_declarator") {
                TSNode nameNode = TreeSitterParser.getChildByFieldName(child, "name");
                TSNode valueNode = TreeSitterParser.getChildByFieldName(child, "value");

                if (!TreeSitterParser.isValid(nameNode))
                    continue;

                string name = TreeSitterParser.getNodeText(nameNode, sourceText);
                Expression initializer = null;
                if (TreeSitterParser.isValid(valueNode))
                    initializer = parseExpression(valueNode);

                // null type → type checker will auto-infer from initializer
                result ~= new VariableDecl(loc, name, null, initializer);
            }
        }
        return result;
    }

    // ------------------------------------------------------------------
    // Class declaration
    // ------------------------------------------------------------------

    private Declaration parseClassDeclaration(TSNode node, SourceLocation loc) {
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");

        if (!TreeSitterParser.isValid(nameNode))
            throw new ParseError("JS class declaration missing name", loc);

        string name = TreeSitterParser.getNodeText(nameNode, sourceText);
        Declaration[] members;

        if (TreeSitterParser.isValid(bodyNode)) {
            // class_body contains method_definition children
            uint childCount = TreeSitterParser.getChildCount(bodyNode);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(bodyNode, i);
                string childType = TreeSitterParser.getNodeType(child);

                if (childType == "method_definition") {
                    auto method = parseMethodDefinition(child, makeSourceLocation(child));
                    if (method !is null)
                        members ~= method;
                }
            }
        }

        // JS classes → D ClassDecl with no base class or interfaces
        return new ClassDecl(loc, name, null, null, members);
    }

    // ------------------------------------------------------------------
    // Method definition (inside class)
    // ------------------------------------------------------------------

    private Declaration parseMethodDefinition(TSNode node, SourceLocation loc) {
        TSNode nameNode = TreeSitterParser.getChildByFieldName(node, "name");
        TSNode paramsNode = TreeSitterParser.getChildByFieldName(node, "parameters");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");

        if (!TreeSitterParser.isValid(nameNode))
            return null;

        string name = TreeSitterParser.getNodeText(nameNode, sourceText);

        // Skip constructor for now — it maps to D 'this()'
        if (name == "constructor")
            return null;

        Parameter[] parameters = parseFormalParameters(paramsNode);

        Statement body_;
        if (TreeSitterParser.isValid(bodyNode))
            body_ = parseStatementBlock(bodyNode);
        else
            body_ = null;

        auto returnType = defaultType(loc);
        return new FunctionDecl(loc, name, returnType, parameters, body_);
    }

    // ------------------------------------------------------------------
    // Export statement (unwrap)
    // ------------------------------------------------------------------

    private Declaration[] parseExportStatement(TSNode node, SourceLocation loc) {
        TSNode declNode = TreeSitterParser.getChildByFieldName(node, "declaration");
        if (TreeSitterParser.isValid(declNode))
            return parseTopLevel(declNode);

        // export { ... } or export default — skip for v1
        return [];
    }

    // ------------------------------------------------------------------
    // Formal parameters
    // ------------------------------------------------------------------

    private Parameter[] parseFormalParameters(TSNode node) {
        Parameter[] params;
        if (!TreeSitterParser.isValid(node))
            return params;

        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);

            if (childType == "identifier") {
                string name = TreeSitterParser.getNodeText(child, sourceText);
                auto loc = makeSourceLocation(child);
                params ~= Parameter(defaultType(loc), name, null);
            }
            // Skip: rest_pattern, assignment_pattern (default values), destructuring
        }
        return params;
    }

    // ------------------------------------------------------------------
    // Statements
    // ------------------------------------------------------------------

    Statement parseStatement(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        string nodeType = TreeSitterParser.getNodeType(node);

        log(3, "JS parsing statement: ", nodeType);

        switch (nodeType) {
        case "statement_block":
            return parseStatementBlock(node);

        case "return_statement":
            return parseReturnStatement(node, loc);

        case "if_statement":
            return parseIfStatement(node, loc);

        case "while_statement":
            return parseWhileStatement(node, loc);

        case "for_statement":
            return parseForStatement(node, loc);

        case "expression_statement":
            return parseExpressionStatement(node, loc);

        case "variable_declaration":
        case "lexical_declaration":
            return parseVarDeclStatement(node, loc);

        case "break_statement":
            return new BreakStatement(loc);

        case "continue_statement":
            return new ContinueStatement(loc);

        case "empty_statement":
            return new CompoundStatement(loc, []);

        case "comment":
            return null;

        default:
            throw new ParseError("Unknown JS statement node: " ~ nodeType, loc);
        }
    }

    // ------------------------------------------------------------------
    // Statement block → CompoundStatement
    // ------------------------------------------------------------------

    private Statement parseStatementBlock(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        Statement[] stmts;

        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);

            // Skip braces and comments
            if (childType == "{" || childType == "}" || childType == "comment")
                continue;

            auto stmt = parseStatement(child);
            if (stmt !is null)
                stmts ~= stmt;
        }

        return new CompoundStatement(loc, stmts);
    }

    // ------------------------------------------------------------------
    // Return statement
    // ------------------------------------------------------------------

    private Statement parseReturnStatement(TSNode node, SourceLocation loc) {
        // return_statement has optional expression child
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType != "return" && childType != ";") {
                auto expr = parseExpression(child);
                return new ReturnStatement(loc, expr);
            }
        }
        return new ReturnStatement(loc, null);
    }

    // ------------------------------------------------------------------
    // If statement
    // ------------------------------------------------------------------

    private Statement parseIfStatement(TSNode node, SourceLocation loc) {
        TSNode condNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode consNode = TreeSitterParser.getChildByFieldName(node, "consequence");
        TSNode altNode = TreeSitterParser.getChildByFieldName(node, "alternative");

        Expression condition;
        if (TreeSitterParser.isValid(condNode)) {
            // condition is wrapped in parenthesized_expression
            condition = parseExpression(condNode);
        } else {
            throw new ParseError("JS if statement missing condition", loc);
        }

        Statement thenStmt = TreeSitterParser.isValid(consNode)
            ? parseStatement(consNode) : new CompoundStatement(loc, []);

        Statement elseStmt = null;
        if (TreeSitterParser.isValid(altNode)) {
            // else_clause wraps the actual statement
            string altType = TreeSitterParser.getNodeType(altNode);
            if (altType == "else_clause") {
                // First named child of else_clause is the statement
                uint altCount = TreeSitterParser.getChildCount(altNode);
                for (uint i = 0; i < altCount; i++) {
                    TSNode altChild = TreeSitterParser.getChild(altNode, i);
                    string altChildType = TreeSitterParser.getNodeType(altChild);
                    if (altChildType != "else") {
                        elseStmt = parseStatement(altChild);
                        break;
                    }
                }
            } else {
                elseStmt = parseStatement(altNode);
            }
        }

        return new IfStatement(loc, condition, thenStmt, elseStmt);
    }

    // ------------------------------------------------------------------
    // While statement
    // ------------------------------------------------------------------

    private Statement parseWhileStatement(TSNode node, SourceLocation loc) {
        TSNode condNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");

        Expression condition;
        if (TreeSitterParser.isValid(condNode))
            condition = parseExpression(condNode);
        else
            throw new ParseError("JS while statement missing condition", loc);

        Statement body_ = TreeSitterParser.isValid(bodyNode)
            ? parseStatement(bodyNode) : new CompoundStatement(loc, []);

        return new WhileStatement(loc, condition, body_);
    }

    // ------------------------------------------------------------------
    // For statement
    // ------------------------------------------------------------------

    private Statement parseForStatement(TSNode node, SourceLocation loc) {
        TSNode initNode = TreeSitterParser.getChildByFieldName(node, "initializer");
        TSNode condNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode incrNode = TreeSitterParser.getChildByFieldName(node, "increment");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");

        Statement init_;
        if (TreeSitterParser.isValid(initNode)) {
            string initType = TreeSitterParser.getNodeType(initNode);
            if (initType == "variable_declaration" || initType == "lexical_declaration")
                init_ = parseVarDeclStatement(initNode, makeSourceLocation(initNode));
            else
                init_ = new ExpressionStatement(makeSourceLocation(initNode), parseExpression(initNode));
        } else {
            init_ = null;
        }

        Expression condition;
        if (TreeSitterParser.isValid(condNode))
            condition = parseExpression(condNode);
        else
            condition = null;

        Expression increment;
        if (TreeSitterParser.isValid(incrNode))
            increment = parseExpression(incrNode);
        else
            increment = null;

        Statement body_ = TreeSitterParser.isValid(bodyNode)
            ? parseStatement(bodyNode) : new CompoundStatement(loc, []);

        return new ForStatement(loc, init_, condition, increment, body_);
    }

    // ------------------------------------------------------------------
    // Expression statement
    // ------------------------------------------------------------------

    private Statement parseExpressionStatement(TSNode node, SourceLocation loc) {
        // expression_statement has one expression child (plus optional semicolon)
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType != ";") {
                auto expr = parseExpression(child);
                return new ExpressionStatement(loc, expr);
            }
        }
        throw new ParseError("Empty expression statement", loc);
    }

    // ------------------------------------------------------------------
    // Variable declaration statement (let/const/var inside function)
    // ------------------------------------------------------------------

    private Statement parseVarDeclStatement(TSNode node, SourceLocation loc) {
        // A lexical_declaration/variable_declaration wraps variable_declarator(s)
        // For simplicity, we only handle the first declarator as a statement
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);

            if (childType == "variable_declarator") {
                TSNode nameNode = TreeSitterParser.getChildByFieldName(child, "name");
                TSNode valueNode = TreeSitterParser.getChildByFieldName(child, "value");

                if (!TreeSitterParser.isValid(nameNode))
                    continue;

                string name = TreeSitterParser.getNodeText(nameNode, sourceText);
                Expression initializer = null;
                if (TreeSitterParser.isValid(valueNode))
                    initializer = parseExpression(valueNode);

                // null type → auto-infer
                return new VariableDeclarationStatement(loc, name, null, initializer);
            }
        }
        throw new ParseError("Variable declaration has no declarators", loc);
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    Expression parseExpression(TSNode node) {
        SourceLocation loc = makeSourceLocation(node);
        string nodeType = TreeSitterParser.getNodeType(node);

        log(3, "JS parsing expression: ", nodeType);

        switch (nodeType) {
        case "binary_expression":
            return parseBinaryExpression(node, loc);

        case "unary_expression":
            return parseUnaryExpression(node, loc);

        case "update_expression":
            return parseUpdateExpression(node, loc);

        case "assignment_expression":
            return parseAssignmentExpression(node, loc);

        case "augmented_assignment_expression":
            return parseAugmentedAssignmentExpression(node, loc);

        case "call_expression":
            return parseCallExpression(node, loc);

        case "member_expression":
            return parseMemberExpression(node, loc);

        case "subscript_expression":
            return parseSubscriptExpression(node, loc);

        case "ternary_expression":
            return parseTernaryExpression(node, loc);

        case "parenthesized_expression":
            return parseParenthesizedExpression(node, loc);

        case "arrow_function":
            return parseArrowFunction(node, loc);

        case "new_expression":
            return parseNewExpression(node, loc);

        case "identifier":
            return new IdentifierExpression(loc, TreeSitterParser.getNodeText(node, sourceText));

        case "this":
            return new IdentifierExpression(loc, "this");

        case "number":
            return parseNumberLiteral(node, loc);

        case "string":
            return parseStringLiteral(node, loc);

        case "true":
            return LiteralExpression.boolean(loc, true);

        case "false":
            return LiteralExpression.boolean(loc, false);

        case "null":
            return LiteralExpression.null_(loc);

        case "undefined":
            return LiteralExpression.integer(loc, 0);

        case "array":
            return parseArrayLiteral(node, loc);

        case "sequence_expression":
            // comma expression: evaluate all, return last
            return parseSequenceExpression(node, loc);

        default:
            throw new ParseError("Unknown JS expression node: " ~ nodeType, loc);
        }
    }

    // ------------------------------------------------------------------
    // Binary expression
    // ------------------------------------------------------------------

    private Expression parseBinaryExpression(TSNode node, SourceLocation loc) {
        TSNode leftNode = TreeSitterParser.getChildByFieldName(node, "left");
        TSNode rightNode = TreeSitterParser.getChildByFieldName(node, "right");

        if (!TreeSitterParser.isValid(leftNode) || !TreeSitterParser.isValid(rightNode))
            throw new ParseError("Binary expression missing operands", loc);

        Expression left = parseExpression(leftNode);
        Expression right = parseExpression(rightNode);

        // The operator is an anonymous node between left and right
        // Find it by scanning children
        string opText = findOperatorText(node);
        auto op = parseBinaryOperator(opText, loc);

        return new BinaryExpression(loc, left, op, right);
    }

    private string findOperatorText(TSNode node) {
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            // Operators are anonymous nodes (not named) — their type IS the operator text
            // In tree-sitter, anonymous nodes have type like "+", "-", "===", etc.
            if (isOperatorToken(childType))
                return childType;
        }
        return "";
    }

    private static bool isOperatorToken(string s) {
        if (s.length == 0) return false;
        // Operators are short strings of symbolic characters
        foreach (c; s) {
            if (c != '+' && c != '-' && c != '*' && c != '/' && c != '%'
                && c != '=' && c != '!' && c != '<' && c != '>'
                && c != '&' && c != '|' && c != '^' && c != '~')
                return false;
        }
        return true;
    }

    private BinaryExpression.Operator parseBinaryOperator(string op, SourceLocation loc) {
        switch (op) {
            case "+": return BinaryExpression.Operator.Add;
            case "-": return BinaryExpression.Operator.Subtract;
            case "*": return BinaryExpression.Operator.Multiply;
            case "/": return BinaryExpression.Operator.Divide;
            case "%": return BinaryExpression.Operator.Modulo;
            case "==": return BinaryExpression.Operator.Equal;
            case "===": return BinaryExpression.Operator.Equal;
            case "!=": return BinaryExpression.Operator.NotEqual;
            case "!==": return BinaryExpression.Operator.NotEqual;
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
            default:
                throw new ParseError("Unknown JS binary operator: " ~ op, loc);
        }
    }

    // ------------------------------------------------------------------
    // Unary expression
    // ------------------------------------------------------------------

    private Expression parseUnaryExpression(TSNode node, SourceLocation loc) {
        TSNode argNode = TreeSitterParser.getChildByFieldName(node, "argument");
        if (!TreeSitterParser.isValid(argNode))
            throw new ParseError("Unary expression missing operand", loc);

        Expression operand = parseExpression(argNode);
        string opText = findOperatorText(node);

        // Handle 'typeof' and 'void' — not real operators for us
        if (opText.length == 0) {
            // Check for keyword operators
            uint childCount = TreeSitterParser.getChildCount(node);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(node, i);
                string childType = TreeSitterParser.getNodeType(child);
                if (childType == "typeof" || childType == "void" || childType == "delete") {
                    // Return the operand as-is (best effort)
                    return operand;
                }
            }
        }

        UnaryExpression.Operator op;
        switch (opText) {
            case "-": op = UnaryExpression.Operator.Minus; break;
            case "+": op = UnaryExpression.Operator.Plus; break;
            case "!": op = UnaryExpression.Operator.LogicalNot; break;
            case "~": op = UnaryExpression.Operator.BitwiseNot; break;
            default:
                // Unknown unary op — return operand
                return operand;
        }

        return new UnaryExpression(loc, op, operand);
    }

    // ------------------------------------------------------------------
    // Update expression (++/--)
    // ------------------------------------------------------------------

    private Expression parseUpdateExpression(TSNode node, SourceLocation loc) {
        TSNode argNode = TreeSitterParser.getChildByFieldName(node, "argument");
        if (!TreeSitterParser.isValid(argNode))
            throw new ParseError("Update expression missing argument", loc);

        Expression operand = parseExpression(argNode);

        // Determine prefix vs postfix and ++ vs --
        // In tree-sitter: prefix has operator as first child, postfix has it as last
        TSNode firstChild = TreeSitterParser.getChild(node, 0);
        string firstType = TreeSitterParser.getNodeType(firstChild);
        bool isPrefix = (firstType == "++" || firstType == "--");

        string opText = findOperatorText(node);
        // Fallback: check the non-argument children
        if (opText.length == 0) {
            opText = firstType;
            if (!isOperatorToken(opText)) {
                uint cc = TreeSitterParser.getChildCount(node);
                if (cc > 1) {
                    auto lastChild = TreeSitterParser.getChild(node, cc - 1);
                    opText = TreeSitterParser.getNodeType(lastChild);
                }
            }
        }

        UnaryExpression.Operator op;
        if (opText == "++") {
            op = isPrefix ? UnaryExpression.Operator.PreIncrement
                          : UnaryExpression.Operator.PostIncrement;
        } else {
            op = isPrefix ? UnaryExpression.Operator.PreDecrement
                          : UnaryExpression.Operator.PostDecrement;
        }

        return new UnaryExpression(loc, op, operand, !isPrefix);
    }

    // ------------------------------------------------------------------
    // Assignment expression
    // ------------------------------------------------------------------

    private Expression parseAssignmentExpression(TSNode node, SourceLocation loc) {
        TSNode leftNode = TreeSitterParser.getChildByFieldName(node, "left");
        TSNode rightNode = TreeSitterParser.getChildByFieldName(node, "right");

        if (!TreeSitterParser.isValid(leftNode) || !TreeSitterParser.isValid(rightNode))
            throw new ParseError("Assignment expression missing operands", loc);

        Expression left = parseExpression(leftNode);
        Expression right = parseExpression(rightNode);

        return new AssignmentExpression(loc, left, AssignmentExpression.Operator.Assign, right);
    }

    // ------------------------------------------------------------------
    // Augmented assignment expression (+=, -=, etc.)
    // ------------------------------------------------------------------

    private Expression parseAugmentedAssignmentExpression(TSNode node, SourceLocation loc) {
        TSNode leftNode = TreeSitterParser.getChildByFieldName(node, "left");
        TSNode rightNode = TreeSitterParser.getChildByFieldName(node, "right");

        if (!TreeSitterParser.isValid(leftNode) || !TreeSitterParser.isValid(rightNode))
            throw new ParseError("Augmented assignment expression missing operands", loc);

        Expression left = parseExpression(leftNode);
        Expression right = parseExpression(rightNode);

        string opText = findOperatorText(node);
        auto op = parseAssignmentOperator(opText, loc);

        return new AssignmentExpression(loc, left, op, right);
    }

    private AssignmentExpression.Operator parseAssignmentOperator(string op, SourceLocation loc) {
        switch (op) {
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
                throw new ParseError("Unknown JS assignment operator: " ~ op, loc);
        }
    }

    // ------------------------------------------------------------------
    // Call expression
    // ------------------------------------------------------------------

    private Expression parseCallExpression(TSNode node, SourceLocation loc) {
        TSNode funcNode = TreeSitterParser.getChildByFieldName(node, "function");
        TSNode argsNode = TreeSitterParser.getChildByFieldName(node, "arguments");

        if (!TreeSitterParser.isValid(funcNode))
            throw new ParseError("Call expression missing function", loc);

        Expression func = parseExpression(funcNode);
        Expression[] args;

        if (TreeSitterParser.isValid(argsNode)) {
            uint childCount = TreeSitterParser.getChildCount(argsNode);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(argsNode, i);
                string childType = TreeSitterParser.getNodeType(child);
                // Skip parens and commas
                if (childType == "(" || childType == ")" || childType == ",")
                    continue;
                args ~= parseExpression(child);
            }
        }

        return new CallExpression(loc, func, args);
    }

    // ------------------------------------------------------------------
    // Member expression (obj.prop)
    // ------------------------------------------------------------------

    private Expression parseMemberExpression(TSNode node, SourceLocation loc) {
        TSNode objNode = TreeSitterParser.getChildByFieldName(node, "object");
        TSNode propNode = TreeSitterParser.getChildByFieldName(node, "property");

        if (!TreeSitterParser.isValid(objNode) || !TreeSitterParser.isValid(propNode))
            throw new ParseError("Member expression missing object or property", loc);

        Expression obj = parseExpression(objNode);
        string prop = TreeSitterParser.getNodeText(propNode, sourceText);

        return new MemberExpression(loc, obj, prop);
    }

    // ------------------------------------------------------------------
    // Subscript expression (arr[idx])
    // ------------------------------------------------------------------

    private Expression parseSubscriptExpression(TSNode node, SourceLocation loc) {
        TSNode objNode = TreeSitterParser.getChildByFieldName(node, "object");
        TSNode idxNode = TreeSitterParser.getChildByFieldName(node, "index");

        if (!TreeSitterParser.isValid(objNode) || !TreeSitterParser.isValid(idxNode))
            throw new ParseError("Subscript expression missing object or index", loc);

        Expression obj = parseExpression(objNode);
        Expression idx = parseExpression(idxNode);

        return new IndexExpression(loc, obj, idx);
    }

    // ------------------------------------------------------------------
    // Ternary expression (a ? b : c)
    // ------------------------------------------------------------------

    private Expression parseTernaryExpression(TSNode node, SourceLocation loc) {
        TSNode condNode = TreeSitterParser.getChildByFieldName(node, "condition");
        TSNode consNode = TreeSitterParser.getChildByFieldName(node, "consequence");
        TSNode altNode = TreeSitterParser.getChildByFieldName(node, "alternative");

        if (!TreeSitterParser.isValid(condNode) || !TreeSitterParser.isValid(consNode)
                || !TreeSitterParser.isValid(altNode))
            throw new ParseError("Ternary expression missing operands", loc);

        Expression cond = parseExpression(condNode);
        Expression cons = parseExpression(consNode);
        Expression alt = parseExpression(altNode);

        // D has no TernaryExpression — lower to if-then-else?
        // Actually we can use the same pattern as the D bridge if one exists.
        // For now, use a FunctionLiteralExpression or just pick the D approach.
        // Wait — let me check... the D compiler doesn't have a ternary expression AST node.
        // The D bridge doesn't handle ternary either. We need to handle this differently.
        // Actually looking at the D bridge there's no ternary — it would be parsed differently in D.

        // For v1: lower `a ? b : c` to an if-expression isn't possible without TernaryExpression.
        // Let's just return the consequence for now (best effort) or throw.
        // Actually, we should just implement it properly. Let me use conditional logic.
        // The simplest approach: we can create a synthetic call or just emit the condition.
        // Actually — let me just throw for now, this is v1.
        throw new ParseError("JS ternary expressions not yet supported", loc);
    }

    // ------------------------------------------------------------------
    // Parenthesized expression (unwrap)
    // ------------------------------------------------------------------

    private Expression parseParenthesizedExpression(TSNode node, SourceLocation loc) {
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

    // ------------------------------------------------------------------
    // Arrow function → FunctionLiteralExpression
    // ------------------------------------------------------------------

    private Expression parseArrowFunction(TSNode node, SourceLocation loc) {
        TSNode paramNode = TreeSitterParser.getChildByFieldName(node, "parameter");
        TSNode paramsNode = TreeSitterParser.getChildByFieldName(node, "parameters");
        TSNode bodyNode = TreeSitterParser.getChildByFieldName(node, "body");

        Parameter[] params;
        string singleParamName;

        // Single param: x => ...
        if (TreeSitterParser.isValid(paramNode)) {
            singleParamName = TreeSitterParser.getNodeText(paramNode, sourceText);
            params ~= Parameter(defaultType(loc), singleParamName, null);
        }
        // Multiple params: (a, b) => ...
        if (TreeSitterParser.isValid(paramsNode))
            params = parseFormalParameters(paramsNode);

        Statement body_;
        Expression arrowBody;

        if (TreeSitterParser.isValid(bodyNode)) {
            string bodyType = TreeSitterParser.getNodeType(bodyNode);
            if (bodyType == "statement_block") {
                body_ = parseStatementBlock(bodyNode);
                arrowBody = null;
            } else {
                // Expression body: x => x + 1
                arrowBody = parseExpression(bodyNode);
                body_ = new CompoundStatement(loc, [new ReturnStatement(loc, arrowBody)]);
            }
        } else {
            body_ = null;
            arrowBody = null;
        }

        return new FunctionLiteralExpression(loc, false, null, params,
            body_, arrowBody, singleParamName);
    }

    // ------------------------------------------------------------------
    // New expression
    // ------------------------------------------------------------------

    private Expression parseNewExpression(TSNode node, SourceLocation loc) {
        TSNode ctorNode = TreeSitterParser.getChildByFieldName(node, "constructor");
        TSNode argsNode = TreeSitterParser.getChildByFieldName(node, "arguments");

        if (!TreeSitterParser.isValid(ctorNode))
            throw new ParseError("New expression missing constructor", loc);

        string typeName = TreeSitterParser.getNodeText(ctorNode, sourceText);
        auto allocType = new UserType(loc, typeName);

        Expression[] args;
        if (TreeSitterParser.isValid(argsNode)) {
            uint childCount = TreeSitterParser.getChildCount(argsNode);
            for (uint i = 0; i < childCount; i++) {
                TSNode child = TreeSitterParser.getChild(argsNode, i);
                string childType = TreeSitterParser.getNodeType(child);
                if (childType == "(" || childType == ")" || childType == ",")
                    continue;
                args ~= parseExpression(child);
            }
        }

        return new NewExpression(loc, allocType, args);
    }

    // ------------------------------------------------------------------
    // Array literal
    // ------------------------------------------------------------------

    private Expression parseArrayLiteral(TSNode node, SourceLocation loc) {
        Expression[] elements;

        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType == "[" || childType == "]" || childType == ",")
                continue;
            elements ~= parseExpression(child);
        }

        return new ArrayLiteralExpression(loc, elements);
    }

    // ------------------------------------------------------------------
    // Number literal
    // ------------------------------------------------------------------

    private Expression parseNumberLiteral(TSNode node, SourceLocation loc) {
        string text = TreeSitterParser.getNodeText(node, sourceText);

        // Check if it's a float (has decimal point or exponent)
        bool isFloat = false;
        foreach (c; text) {
            if (c == '.' || c == 'e' || c == 'E') {
                isFloat = true;
                break;
            }
        }

        if (isFloat) {
            try {
                return LiteralExpression.floating(loc, to!double(text));
            } catch (Exception) {
                return LiteralExpression.integer(loc, 0);
            }
        }

        // Integer — handle hex (0x), octal (0o), binary (0b)
        try {
            if (text.startsWith("0x") || text.startsWith("0X")) {
                string digits = text[2..$];
                long val = parse!long(digits, 16);
                return LiteralExpression.integer(loc, val);
            }
            if (text.startsWith("0b") || text.startsWith("0B")) {
                string digits = text[2..$];
                long val = parse!long(digits, 2);
                return LiteralExpression.integer(loc, val);
            }
            if (text.startsWith("0o") || text.startsWith("0O")) {
                string digits = text[2..$];
                long val = parse!long(digits, 8);
                return LiteralExpression.integer(loc, val);
            }
            return LiteralExpression.integer(loc, to!long(text));
        } catch (Exception) {
            return LiteralExpression.integer(loc, 0);
        }
    }

    // ------------------------------------------------------------------
    // String literal
    // ------------------------------------------------------------------

    private Expression parseStringLiteral(TSNode node, SourceLocation loc) {
        string text = TreeSitterParser.getNodeText(node, sourceText);

        // JS strings can be single-quoted or double-quoted
        // Remove the surrounding quotes
        if (text.length >= 2) {
            char quote = text[0];
            if ((quote == '"' || quote == '\'') && text[$ - 1] == quote) {
                string inner = text[1 .. $ - 1];
                string unescaped = unescapeJSString(inner);
                return LiteralExpression.string_(loc, unescaped);
            }
        }

        // Fallback: return raw text
        return LiteralExpression.string_(loc, text);
    }

    // ------------------------------------------------------------------
    // Sequence expression (comma operator)
    // ------------------------------------------------------------------

    private Expression parseSequenceExpression(TSNode node, SourceLocation loc) {
        // Return the last expression in the sequence
        Expression last;
        uint childCount = TreeSitterParser.getChildCount(node);
        for (uint i = 0; i < childCount; i++) {
            TSNode child = TreeSitterParser.getChild(node, i);
            string childType = TreeSitterParser.getNodeType(child);
            if (childType != ",")
                last = parseExpression(child);
        }
        if (last !is null) return last;
        throw new ParseError("Empty sequence expression", loc);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private Type defaultType(SourceLocation loc) {
        return new BasicType(loc, BasicType.Kind.Int32);
    }

    private SourceLocation makeSourceLocation(TSNode node) {
        import parser.tree_sitter_c : ts_node_start_byte, ts_node_end_byte;

        auto startPoint = TreeSitterParser.getStartPoint(node);
        auto endPoint = TreeSitterParser.getEndPoint(node);

        return SourceLocation(
            filename,
            startPoint.row + 1,
            startPoint.column + 1,
            ts_node_start_byte(node),
            ts_node_end_byte(node)
        );
    }

    private static string unescapeJSString(string s) {
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
}
