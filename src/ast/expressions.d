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
        ShiftLeft, ShiftRight, UnsignedShiftRight,

        // Array/String
        Concat  // ~ operator
    }

    Expression left;
    Operator operator;
    Expression right;
    Expression loweredCall;  // Set by type checker for shift/comparison lowering

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
            case Operator.UnsignedShiftRight: return ">>>";
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
    FunctionDecl resolvedInstantiation;  // Set by IFTI during type checking
    StructDecl resolvedEmplaceStruct;  // Set by type checker for emplace() calls
    
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
 * Template instantiation call: templateName!typeArgs(callArgs)
 * E.g. max!int(3, 5)
 */
class TemplateInstantiationExpression : Expression {
    string templateName;
    Type[] templateArguments;
    Expression[] templateArgExpressions;  // Parallel to templateArguments: non-null at value param positions
    Expression[] callArguments;

    // Set during semantic analysis
    FunctionDecl resolvedInstantiation;
    StructDecl resolvedStructInstantiation;  // Non-null for struct template construction

    this(SourceLocation loc, string templateName, Type[] templateArguments, Expression[] callArguments) {
        super(loc);
        this.templateName = templateName;
        this.templateArguments = templateArguments;
        this.callArguments = callArguments;
    }

    override bool isConstant() const { return false; }
    override bool hasLValue() const { return false; }

    override string toString() const {
        import std.algorithm : map;
        import std.array : join, array;
        string typeStr = templateArguments.map!(t => t.toString()).array.join(", ");
        string argStr = callArguments.map!(a => a.toString()).array.join(", ");
        return format("%s!(%s)(%s)", templateName, typeStr, argStr);
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
    bool isAutoDereference;  // true when object is a pointer type (auto-deref for p.field)

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
    
    // Set by type checker - the uniqueLocalId of the resolved variable/parameter
    // uint.max means not resolved or not a local variable
    uint resolvedLocalId = uint.max;
    
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
    
    // Resolved by type checker for class→interface casts
    ClassDecl sourceClassDecl;
    InterfaceDecl targetInterfaceDecl;
    
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
    Expression loweredCall;  // Set by type checker for shift compound assignments

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

/**
 * is(...) expression: compile-time type introspection.
 * Forms: is(T), is(T == int), is(T == struct), is(T : int)
 */
class IsExpression : Expression {
    Type checkedType;       // The type being tested
    string operator;        // "==" or ":" or null (bare is(T))
    Type specType;          // Specific type for == or : (e.g., int)
    string specKeyword;     // Category keyword: "struct", "class", "interface", "enum", null
    bool boolResult;
    bool evaluated;

    this(SourceLocation loc, Type checkedType, string operator = null,
         Type specType = null, string specKeyword = null) {
        super(loc);
        this.checkedType = checkedType;
        this.operator = operator;
        this.specType = specType;
        this.specKeyword = specKeyword;
    }

    override bool isConstant() const { return true; }
    override bool hasLValue() const { return false; }

    override string toString() const {
        if (operator is null)
            return format("is(%s)", checkedType);
        if (specKeyword !is null)
            return format("is(%s %s %s)", checkedType, operator, specKeyword);
        return format("is(%s %s %s)", checkedType, operator, specType);
    }
}

/**
 * __traits expression: __traits(keyword, args...)
 * Evaluates to a compile-time constant based on type/symbol properties.
 */
class TraitsExpression : Expression {
    string traitName;           // e.g. "isArithmetic", "hasMember", "compiles"
    Expression[] arguments;     // expression args (null where type arg occupies the slot)
    Type[] typeArguments;       // type args (null where expr arg occupies the slot)

    // Evaluation results (set during semantic analysis)
    bool boolResult;
    string stringResult;
    string[] stringArrayResult;  // For allMembers
    bool evaluated = false;

    this(SourceLocation loc, string traitName, Expression[] arguments, Type[] typeArguments) {
        super(loc);
        this.traitName = traitName;
        this.arguments = arguments;
        this.typeArguments = typeArguments;
    }

    /**
     * Self-evaluate the __traits expression in-place.
     * This is the canonical evaluation method — called from mixin_expander,
     * type_checker, and emitters. Callers that need UserType resolution
     * (e.g. for hasMember) should resolve typeArguments before calling this.
     */
    void evaluate() {
        if (evaluated) return;

        Type resolvedType = (typeArguments.length > 0) ? typeArguments[0] : null;

        switch (traitName) {
            case "isArithmetic":
                if (auto bt = cast(BasicType)resolvedType)
                    boolResult = isIntegerKind(bt.kind) || isFloatingKind(bt.kind);
                break;
            case "isIntegral":
                if (auto bt = cast(BasicType)resolvedType)
                    boolResult = isIntegerKind(bt.kind);
                break;
            case "isFloating":
                if (auto bt = cast(BasicType)resolvedType)
                    boolResult = isFloatingKind(bt.kind);
                break;
            case "isUnsigned":
                if (auto bt = cast(BasicType)resolvedType)
                    boolResult = isUnsignedKind(bt.kind);
                break;
            case "isSigned":
                if (auto bt = cast(BasicType)resolvedType)
                    boolResult = isSignedKind(bt.kind);
                break;
            case "isStaticArray":
                if (auto at = cast(ArrayType)resolvedType)
                    boolResult = at.isStaticArray;
                break;
            case "isArray":
                boolResult = resolvedType !is null && resolvedType.isArray();
                break;
            case "hasMember":
                boolResult = evaluateHasMember(resolvedType);
                break;
            case "identifier":
                if (arguments.length > 0) {
                    if (auto ident = cast(IdentifierExpression)arguments[0])
                        stringResult = ident.name;
                }
                break;
            case "allMembers":
                stringArrayResult = evaluateAllMembers(resolvedType);
                break;
            default:
                assert(0, "unhandled __trait: " ~ traitName);
        }
        evaluated = true;
    }

    private bool evaluateHasMember(Type resolvedType) {
        if (resolvedType is null) return false;

        string memberName;
        if (arguments.length >= 2 && arguments[1] !is null) {
            if (auto lit = cast(LiteralExpression)arguments[1]) {
                if (lit.value.type == typeid(string))
                    memberName = lit.value.get!string;
            }
        }
        if (memberName.length == 0) return false;

        if (auto sd = resolvedType.asStruct()) {
            foreach (m; sd.members)
                if (m.name == memberName) return true;
        } else if (auto cd = resolvedType.asClass()) {
            foreach (m; cd.members)
                if (m.name == memberName) return true;
        }
        return false;
    }

    private string[] evaluateAllMembers(Type resolvedType) {
        if (resolvedType is null) return [];
        string[] result;
        if (auto sd = resolvedType.asStruct()) {
            foreach (m; sd.members)
                result ~= m.name;
        } else if (auto cd = resolvedType.asClass()) {
            foreach (m; cd.members)
                result ~= m.name;
        }
        return result;
    }

    override bool isConstant() const {
        return true;  // __traits is always a compile-time constant
    }

    override bool hasLValue() const {
        return false;
    }

    override string toString() const {
        return format("__traits(%s, ...)", traitName);
    }
}

// BasicType.Kind classification helpers for __traits evaluation
private bool isIntegerKind(BasicType.Kind k) {
    return k >= BasicType.Kind.Int8 && k <= BasicType.Kind.UInt64;
}

private bool isFloatingKind(BasicType.Kind k) {
    return k == BasicType.Kind.Float32 || k == BasicType.Kind.Float64;
}

private bool isUnsignedKind(BasicType.Kind k) {
    return k >= BasicType.Kind.UInt8 && k <= BasicType.Kind.UInt64;
}

private bool isSignedKind(BasicType.Kind k) {
    return k >= BasicType.Kind.Int8 && k <= BasicType.Kind.Int64;
}
