/**
 * AST Expression Nodes for D-to-WASM Compiler
 * 
 * This module contains all expression AST node implementations.
 */
module ast.expressions;

import ast.nodes;
import std.string;
import std.conv;
import std.variant;

// ===== EXPRESSIONS =====

/**
 * Binary expression: left op right
 */
class BinaryExpression : Expression {
    enum Operator {
        // Arithmetic
        Add, Subtract, Multiply, Divide, Modulo,
        
        // Comparison
        Equal, NotEqual, Less, LessEqual, Greater, GreaterEqual,
        
        // Logical
        LogicalAnd, LogicalOr,
        
        // Bitwise
        BitwiseAnd, BitwiseOr, BitwiseXor,
        ShiftLeft, ShiftRight,
        
        // Array/String
        Concat  // ~ operator
    }
    
    Expression left;
    Operator operator;
    Expression right;
    
    this(SourceLocation loc, Expression left, Operator operator, Expression right) {
        super(loc);
        this.left = left;
        this.operator = operator;
        this.right = right;
    }
    
    override bool isConstant() const {
        return left.isConstant() && right.isConstant();
    }
    
    override bool hasLValue() const {
        return false;  // Binary expressions are rvalues
    }
    
    
    override string toString() const {
        return format("(%s %s %s)", left.toString(), operatorToString(operator), right.toString());
    }
    
    private static string operatorToString(Operator op) {
        final switch (op) {
            case Operator.Add: return "+";
            case Operator.Subtract: return "-";
            case Operator.Multiply: return "*";
            case Operator.Divide: return "/";
            case Operator.Modulo: return "%";
            case Operator.Equal: return "==";
            case Operator.NotEqual: return "!=";
            case Operator.Less: return "<";
            case Operator.LessEqual: return "<=";
            case Operator.Greater: return ">";
            case Operator.GreaterEqual: return ">=";
            case Operator.LogicalAnd: return "&&";
            case Operator.LogicalOr: return "||";
            case Operator.BitwiseAnd: return "&";
            case Operator.BitwiseOr: return "|";
            case Operator.BitwiseXor: return "^";
            case Operator.ShiftLeft: return "<<";
            case Operator.ShiftRight: return ">>";
            case Operator.Concat: return "~";
        }
    }
}

/**
 * Unary expression: op expression
 */
class UnaryExpression : Expression {
    enum Operator {
        Plus, Minus, LogicalNot, BitwiseNot,
        PreIncrement, PostIncrement,
        PreDecrement, PostDecrement,
        AddressOf, Dereference
    }
    
    Operator operator;
    Expression operand;
    bool isPostfix;  // For increment/decrement operators
    
    this(SourceLocation loc, Operator operator, Expression operand, bool isPostfix = false) {
        super(loc);
        this.operator = operator;
        this.operand = operand;
        this.isPostfix = isPostfix;
    }
    
    override bool isConstant() const {
        // Address-of and dereference are never constant
        if (operator == Operator.AddressOf || operator == Operator.Dereference) {
            return false;
        }
        return operand.isConstant();
    }
    
    override bool hasLValue() const {
        return operator == Operator.Dereference;
    }
    
    
    override string toString() const {
        string opStr = operatorToString(operator);
        if (isPostfix) {
            return format("(%s%s)", operand.toString(), opStr);
        }
        return format("(%s%s)", opStr, operand.toString());
    }
    
    private static string operatorToString(Operator op) {
        final switch (op) {
            case Operator.Plus: return "+";
            case Operator.Minus: return "-";
            case Operator.LogicalNot: return "!";
            case Operator.BitwiseNot: return "~";
            case Operator.PreIncrement, Operator.PostIncrement: return "++";
            case Operator.PreDecrement, Operator.PostDecrement: return "--";
            case Operator.AddressOf: return "&";
            case Operator.Dereference: return "*";
        }
    }
}

/**
 * Function call: function(arguments)
 */
class CallExpression : Expression {
    Expression function_;
    Expression[] arguments;
    bool isUFCS = false;  // Set by type checker for UFCS calls (obj.func() -> func(obj))
    
    this(SourceLocation loc, Expression function_, Expression[] arguments) {
        super(loc);
        this.function_ = function_;
        this.arguments = arguments;
    }
    
    override bool isConstant() const {
        return false;  // Function calls are never constant (for now)
    }
    
    override bool hasLValue() const {
        return false;  // Function calls return rvalues
    }
    
    
    override string toString() const {
        string argStr = "";
        foreach (i, arg; arguments) {
            if (i > 0) argStr ~= ", ";
            argStr ~= arg.toString();
        }
        return format("%s(%s)", function_.toString(), argStr);
    }
}

/**
 * Array indexing: array[index]
 */
class IndexExpression : Expression {
    Expression array;
    Expression index;
    
    // Set by type checker when indexing goes through opIndex
    bool usesOpIndex = false;
    FunctionDecl opIndexMethod;
    
    this(SourceLocation loc, Expression array, Expression index) {
        super(loc);
        this.array = array;
        this.index = index;
    }
    
    override bool isConstant() const {
        return false;  // Array access is never constant
    }
    
    override bool hasLValue() const {
        return true;  // Can assign to array elements
    }
    
    
    override string toString() const {
        return format("%s[%s]", array.toString(), index.toString());
    }
}

/**
 * Slice expression: array[start..end]
 * Creates a view into the array without copying.
 */
class SliceExpression : Expression {
    Expression array;
    Expression start;
    Expression end;
    
    this(SourceLocation loc, Expression array, Expression start, Expression end) {
        super(loc);
        this.array = array;
        this.start = start;
        this.end = end;
    }
    
    override bool isConstant() const {
        return false;
    }
    
    override bool hasLValue() const {
        return false;  // Slice creates a new value (though it's a view)
    }
    
    override string toString() const {
        return format("%s[%s..%s]", array.toString(), start.toString(), end.toString());
    }
}

/**
 * Member access: object.member
 */
class MemberExpression : Expression {
    Expression object;
    string memberName;
    
    this(SourceLocation loc, Expression object, string memberName) {
        super(loc);
        this.object = object;
        this.memberName = memberName;
    }
    
    override bool isConstant() const {
        return false;  // Member access is never constant
    }
    
    override bool hasLValue() const {
        return true;  // Can assign to struct/class members
    }
    
    
    override string toString() const {
        return format("%s.%s", object.toString(), memberName);
    }
}

/**
 * Identifier expression: variable name
 */
class IdentifierExpression : Expression {
    string name;
    Declaration declaration;  // Set during semantic analysis
    
    this(SourceLocation loc, string name) {
        super(loc);
        this.name = name;
    }
    
    override bool isConstant() const {
        // TODO: Check if identifier refers to a constant during semantic analysis
        return false;
    }
    
    override bool hasLValue() const {
        return true;  // Variables can be assigned to
    }
    
    
    override string toString() const {
        return name;
    }
}

/**
 * Literal expression: constant values
 */
class LiteralExpression : Expression {
    Variant value;  // Stores the actual constant value
    
    this(SourceLocation loc, Variant value) {
        super(loc);
        this.value = value;
    }
    
    // Convenience constructors for common literal types
    static LiteralExpression integer(SourceLocation loc, long value) {
        return new LiteralExpression(loc, Variant(value));
    }
    
    static LiteralExpression floating(SourceLocation loc, double value) {
        return new LiteralExpression(loc, Variant(value));
    }
    
    static LiteralExpression boolean(SourceLocation loc, bool value) {
        return new LiteralExpression(loc, Variant(value));
    }
    
    static LiteralExpression string_(SourceLocation loc, string value) {
        return new LiteralExpression(loc, Variant(value));
    }
    
    static LiteralExpression null_(SourceLocation loc) {
        return new LiteralExpression(loc, Variant(null));
    }
    
    static LiteralExpression char_(SourceLocation loc, char value) {
        return new LiteralExpression(loc, Variant(value));
    }
    
    override bool isConstant() const {
        return true;  // Literals are always constant
    }
    
    override bool hasLValue() const {
        return false;  // Literals are rvalues
    }
    
    
    override string toString() const {
        if (value.hasValue) {
            if (value.type == typeid(string)) {
                return format(`"%s"`, value.get!string);
            }
            // Work around const issue with Variant
            return (cast(Variant)value).toString();
        }
        return "null";
    }
}

/**
 * Array literal expression: [1, 2, 3]
 */
class ArrayLiteralExpression : Expression {
    Expression[] elements;
    Type elementType;  // Inferred from elements, or null if empty
    
    this(SourceLocation loc, Expression[] elements) {
        super(loc);
        this.elements = elements;
    }
    
    override bool isConstant() const {
        foreach (elem; elements) {
            if (!elem.isConstant()) return false;
        }
        return true;
    }
    
    override bool hasLValue() const {
        return false;  // Array literals are rvalues
    }
    
    override string toString() const {
        import std.algorithm : map;
        import std.array : array, join;
        string[] parts = elements.map!(e => e.toString()).array;
        return "[" ~ parts.join(", ") ~ "]";
    }
}

/**
 * Cast expression: cast(Type) expression
 */
class CastExpression : Expression {
    Type targetType;
    Expression expression;
    
    this(SourceLocation loc, Type targetType, Expression expression) {
        super(loc);
        this.targetType = targetType;
        this.expression = expression;
    }
    
    override bool isConstant() const {
        return expression.isConstant();
    }
    
    override bool hasLValue() const {
        return false;  // Casts produce rvalues
    }
    
    
    override string toString() const {
        return format("cast(%s)%s", targetType.toString(), expression.toString());
    }
}

/**
 * Assignment expression: left = right
 */
class AssignmentExpression : Expression {
    enum Operator {
        Assign,           // =
        AddAssign,        // +=
        SubtractAssign,   // -=
        MultiplyAssign,   // *=
        DivideAssign,     // /=
        ModuloAssign,     // %=
        AndAssign,        // &=
        OrAssign,         // |=
        XorAssign,        // ^=
        ShiftLeftAssign,  // <<=
        ShiftRightAssign, // >>=
        ConcatAssign      // ~=
    }
    
    Expression left;
    Operator operator;
    Expression right;
    
    this(SourceLocation loc, Expression left, Operator operator, Expression right) {
        super(loc);
        this.left = left;
        this.operator = operator;
        this.right = right;
    }
    
    override bool isConstant() const {
        return false;  // Assignments are never constant
    }
    
    override bool hasLValue() const {
        return false;  // Assignment expressions are rvalues
    }
    
    
    override string toString() const {
        return format("%s %s %s", left.toString(), operatorToString(operator), right.toString());
    }
    
    private static string operatorToString(Operator op) {
        final switch (op) {
            case Operator.Assign: return "=";
            case Operator.AddAssign: return "+=";
            case Operator.SubtractAssign: return "-=";
            case Operator.MultiplyAssign: return "*=";
            case Operator.DivideAssign: return "/=";
            case Operator.ModuloAssign: return "%=";
            case Operator.AndAssign: return "&=";
            case Operator.OrAssign: return "|=";
            case Operator.XorAssign: return "^=";
            case Operator.ShiftLeftAssign: return "<<=";
            case Operator.ShiftRightAssign: return ">>=";
            case Operator.ConcatAssign: return "~=";
        }
    }
}
/**
 * Import expression: import("filename")
 * Reads file contents at compile time (CTFE-only).
 * Returns ubyte[] containing the file bytes.
 */
class ImportExpression : Expression {
    string filename;  // The filename argument (must be a string literal)
    
    this(SourceLocation loc, string filename) {
        super(loc);
        this.filename = filename;
    }
    
    override bool isConstant() const {
        return true;  // import() is evaluated at compile time
    }
    
    override bool hasLValue() const {
        return false;
    }
    
    override string toString() const {
        return format("import(\"%s\")", filename);
    }
}
