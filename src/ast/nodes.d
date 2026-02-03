/**
 * AST Node Hierarchy for D-to-WASM Compiler
 * 
 * This module defines the abstract syntax tree structure for the D language subset
 * supported by the compiler. The design follows these principles:
 * 
 * 1. Clean separation between syntax and semantics
 * 2. Visitor pattern for tree traversal  
 * 3. Source location tracking for error messages
 * 4. Immutable once constructed (functional approach)
 * 5. Specific node types for each supported construct
 */
module ast.nodes;

import std.string;
import std.conv;
import std.bitmanip : bitfields;

// Source location for error reporting
struct SourceLocation {
    string filename;
    uint line;
    uint column;
    uint startOffset;
    uint endOffset;
    
    string toString() const {
        return format("%s:%d:%d", filename, line, column);
    }
}

// Forward declarations will be resolved by importing statements and expressions modules

/**
 * Base class for all AST nodes.
 * Provides common functionality like location tracking and visitor support.
 */
abstract class ASTNode {
    SourceLocation location;
    ASTNode parent;
    
    this(SourceLocation loc) {
        location = loc;
    }
    
    // TODO: Add visitor pattern support later
    abstract override string toString() const;
}

// TODO: Add visitor pattern support in a future iteration

/**
 * Abstract base for all declaration nodes
 */
abstract class Declaration : ASTNode {
    string name;
    bool isPublic;
    
    this(SourceLocation loc, string name, bool isPublic = false) {
        super(loc);
        this.name = name;
        this.isPublic = isPublic;
    }
}

/**
 * Abstract base for all type nodes
 */
abstract class Type : ASTNode {
    this(SourceLocation loc) {
        super(loc);
    }
    
    abstract bool isBasicType() const;
    abstract bool isPointer() const;
    abstract bool isArray() const;
    abstract bool isFunction() const;
    abstract size_t size() const;
    
    /// Get alignment of this type (default: same as size for basic types)
    size_t alignment() const {
        return size();
    }
}

/**
 * Abstract base for all statement nodes
 */
abstract class Statement : ASTNode {
    this(SourceLocation loc) {
        super(loc);
    }
}

/**
 * Abstract base for all expression nodes
 */
abstract class Expression : ASTNode {
    Type type;  // Semantic type - filled during semantic analysis
    
    this(SourceLocation loc) {
        super(loc);
    }
    
    abstract bool isConstant() const;
    abstract bool hasLValue() const;
}

// ===== DECLARATIONS =====

/**
 * Function declaration: returnType name(parameters) contracts { body }
 */
class FunctionDecl : Declaration {
    Type returnType;
    Parameter[] parameters;
    Statement body_;
    string[] attributes;  // @safe, @pure, etc.
    
    // Function kind flags (packed into a single byte)
    mixin(bitfields!(
        bool, "isMethod",    1,  // belongs to struct/class, has implicit `this`
        bool, "isStatic",    1,  // belongs to aggregate but no `this`
        bool, "isProperty",  1,  // @property, called without parens
        bool, "isCTFE",      1,  // CTFE-only function
        uint, "",            4,  // padding to byte boundary
    ));
    
    Declaration parent;  // enclosing struct/class, null for free functions
    
    this(SourceLocation loc, string name, Type returnType, 
         Parameter[] parameters, Statement body_, 
         string[] attributes = [], bool isPublic = false) {
        super(loc, name, isPublic);
        this.returnType = returnType;
        this.parameters = parameters;
        this.body_ = body_;
        this.attributes = attributes;
        this.parent = null;
    }
    
    
    override string toString() const {
        return format("FunctionDecl(%s %s)", returnType.toString(), name);
    }
}

/**
 * Function parameter
 */
struct Parameter {
    Type type;
    string name;
    Expression defaultValue;  // null if no default
    
    string toString() const {
        if (defaultValue) {
            return format("%s %s = %s", type.toString(), name, defaultValue.toString());
        }
        return format("%s %s", type.toString(), name);
    }
}

/**
 * Imported function declaration: extern(WASM, "module") returnType name(params);
 * 
 * Represents a function imported from a WASM host environment.
 * No body - the implementation is provided by the host.
 */
class ImportedFunctionDecl : Declaration {
    Type returnType;
    Parameter[] parameters;
    string moduleName;  // WASM module name (e.g., "console", "env")
    
    this(SourceLocation loc, string name, Type returnType, 
         Parameter[] parameters, string moduleName) {
        super(loc, name, true);  // Always public
        this.returnType = returnType;
        this.parameters = parameters;
        this.moduleName = moduleName;
    }
    
    override string toString() const {
        return format("ImportedFunctionDecl(%s.%s)", moduleName, name);
    }
}

/**
 * Class declaration: class Name : BaseClass, Interface { members }
 */
class ClassDecl : Declaration {
    Type baseClass;  // null if no inheritance
    Type[] interfaces;
    Declaration[] members;
    
    this(SourceLocation loc, string name, Type baseClass, Type[] interfaces,
         Declaration[] members, bool isPublic = false) {
        super(loc, name, isPublic);
        this.baseClass = baseClass;
        this.interfaces = interfaces;
        this.members = members;
    }
    
    
    override string toString() const {
        return format("ClassDecl(%s)", name);
    }
}

/**
 * Struct field layout information
 */
struct StructField {
    string name;
    Type type;
    size_t offset;
    size_t size;
    size_t alignment;
}

/**
 * Struct declaration: struct Name { members }
 */
class StructDecl : Declaration {
    Declaration[] members;
    
    // Layout info (populated during semantic analysis)
    StructField[] fields;
    size_t structSize;
    size_t structAlign;
    bool layoutComputed;
    
    this(SourceLocation loc, string name, Declaration[] members, bool isPublic = false) {
        super(loc, name, isPublic);
        this.members = members;
    }
    
    /**
     * Get field by name, returns null if not found
     */
    StructField* getField(string fieldName) {
        foreach (ref field; fields) {
            if (field.name == fieldName) return &field;
        }
        return null;
    }
    
    override string toString() const {
        return format("StructDecl(%s, size=%d, align=%d)", name, structSize, structAlign);
    }
}

/**
 * Interface declaration: interface Name : ParentInterfaces { methods }
 */
class InterfaceDecl : Declaration {
    Type[] parentInterfaces;
    FunctionDecl[] methods;
    
    this(SourceLocation loc, string name, Type[] parentInterfaces,
         FunctionDecl[] methods, bool isPublic = false) {
        super(loc, name, isPublic);
        this.parentInterfaces = parentInterfaces;
        this.methods = methods;
    }
    
    
    override string toString() const {
        return format("InterfaceDecl(%s)", name);
    }
}

/**
 * Variable declaration: Type name = initializer;
 */
class VariableDecl : Declaration {
    Type type;
    Expression initializer;  // null if no initializer
    
    // CTFE-evaluated struct data (for global immutable structs)
    bool ctfeComplete;
    uint ctfeStructAddress;  // Address in data section where struct is stored
    
    this(SourceLocation loc, string name, Type type, 
         Expression initializer = null, bool isPublic = false) {
        super(loc, name, isPublic);
        this.type = type;
        this.initializer = initializer;
    }
    
    
    override string toString() const {
        return format("VariableDecl(%s %s)", type.toString(), name);
    }
}

/**
 * Enum declaration: enum Name { members }
 */
class EnumDecl : Declaration {
    Type baseType;  // underlying type (int by default)
    EnumMember[] members;
    
    this(SourceLocation loc, string name, Type baseType, 
         EnumMember[] members, bool isPublic = false) {
        super(loc, name, isPublic);
        this.baseType = baseType;
        this.members = members;
    }
    
    
    override string toString() const {
        return format("EnumDecl(%s)", name);
    }
}

struct EnumMember {
    string name;
    Expression value;  // null if auto-calculated
    
    string toString() const {
        if (value) {
            return format("%s = %s", name, value.toString());
        }
        return name;
    }
}

/**
 * Manifest constant: enum NAME = expression;
 * A compile-time constant whose value is determined by CTFE.
 */
class ManifestConstantDecl : Declaration {
    Expression initializer;  // The expression to evaluate at compile time
    Type inferredType;       // Type inferred after CTFE (null before)
    long ctfeValue;          // Value after CTFE evaluation (for integral types)
    string ctfeStringValue;  // Value for string types
    long[] ctfeArrayValue;   // Value for array types (elements as longs)
    ubyte[] ctfeArrayBytes;  // Raw bytes for array data (for codegen)
    uint ctfeElementSize;    // Size of each element in bytes
    bool ctfeComplete;       // Whether CTFE has been performed
    bool isStringType;       // True if this is a string constant
    bool isArrayType;        // True if this is an array constant
    
    this(SourceLocation loc, string name, Expression initializer) {
        super(loc, name, true);  // Manifest constants are always "public" in their scope
        this.initializer = initializer;
        this.inferredType = null;
        this.ctfeComplete = false;
        this.isStringType = false;
        this.isArrayType = false;
    }
    
    override string toString() const {
        if (ctfeComplete) {
            if (isStringType) {
                return format("ManifestConstant(%s = \"%s\")", name, ctfeStringValue);
            }
            return format("ManifestConstant(%s = %d)", name, ctfeValue);
        }
        return format("ManifestConstant(%s = %s)", name, initializer.toString());
    }
}

// ===== TYPES =====

/**
 * Basic types: int, float, bool, void, etc.
 */
class BasicType : Type {
    enum Kind {
        Void, Bool,
        Int8, Int16, Int32, Int64,
        UInt8, UInt16, UInt32, UInt64,
        Float32, Float64,
        Char
    }
    
    Kind kind;
    
    this(SourceLocation loc, Kind kind) {
        super(loc);
        this.kind = kind;
    }
    
    override bool isBasicType() const { return true; }
    override bool isPointer() const { return false; }
    override bool isArray() const { return false; }
    override bool isFunction() const { return false; }
    
    override size_t size() const {
        final switch (kind) {
            case Kind.Void: return 0;
            case Kind.Bool: return 1;
            case Kind.Int8, Kind.UInt8, Kind.Char: return 1;
            case Kind.Int16, Kind.UInt16: return 2;
            case Kind.Int32, Kind.UInt32, Kind.Float32: return 4;
            case Kind.Int64, Kind.UInt64, Kind.Float64: return 8;
        }
    }
    
    
    override string toString() const {
        final switch (kind) {
            case Kind.Void: return "void";
            case Kind.Bool: return "bool";
            case Kind.Int8: return "byte";
            case Kind.Int16: return "short";
            case Kind.Int32: return "int";
            case Kind.Int64: return "long";
            case Kind.UInt8: return "ubyte";
            case Kind.UInt16: return "ushort";
            case Kind.UInt32: return "uint";
            case Kind.UInt64: return "ulong";
            case Kind.Float32: return "float";
            case Kind.Float64: return "double";
            case Kind.Char: return "char";
        }
    }
}

/**
 * Array types: Type[] or Type[size]
 */
class ArrayType : Type {
    Type elementType;
    Expression arraySize;  // null for dynamic arrays
    
    this(SourceLocation loc, Type elementType, Expression arraySize = null) {
        super(loc);
        this.elementType = elementType;
        this.arraySize = arraySize;
    }
    
    override bool isBasicType() const { return false; }
    override bool isPointer() const { return false; }
    override bool isArray() const { return true; }
    override bool isFunction() const { return false; }
    
    override size_t size() const {
        // Dynamic arrays are just pointers (8 bytes on 64-bit)
        if (!arraySize) return 8;
        // Static arrays: element_size * count
        // TODO: evaluate size expression during semantic analysis
        return elementType.size() * 1;  // Placeholder
    }
    
    
    override string toString() const {
        if (arraySize) {
            return format("%s[%s]", elementType.toString(), arraySize.toString());
        }
        return format("%s[]", elementType.toString());
    }
}

/**
 * Pointer types: Type*
 */
class PointerType : Type {
    Type pointeeType;
    
    this(SourceLocation loc, Type pointeeType) {
        super(loc);
        this.pointeeType = pointeeType;
    }
    
    override bool isBasicType() const { return false; }
    override bool isPointer() const { return true; }
    override bool isArray() const { return false; }
    override bool isFunction() const { return false; }
    override size_t size() const { return 8; }  // 64-bit pointers
    
    
    override string toString() const {
        return format("%s*", pointeeType.toString());
    }
}

/**
 * Function types: ReturnType function(Parameters)
 */
class FunctionType : Type {
    Type returnType;
    Type[] parameterTypes;
    
    this(SourceLocation loc, Type returnType, Type[] parameterTypes) {
        super(loc);
        this.returnType = returnType;
        this.parameterTypes = parameterTypes;
    }
    
    override bool isBasicType() const { return false; }
    override bool isPointer() const { return false; }
    override bool isArray() const { return false; }
    override bool isFunction() const { return true; }
    override size_t size() const { return 8; }  // Function pointer size
    
    
    override string toString() const {
        string params = "";
        foreach (i, param; parameterTypes) {
            if (i > 0) params ~= ", ";
            params ~= param.toString();
        }
        return format("%s function(%s)", returnType.toString(), params);
    }
}

/**
 * User-defined types: struct/class/interface names
 */
class UserType : Type {
    string name;
    Declaration declaration;  // Set during semantic analysis
    
    this(SourceLocation loc, string name) {
        super(loc);
        this.name = name;
    }
    
    override bool isBasicType() const { return false; }
    override bool isPointer() const { return false; }
    override bool isArray() const { return false; }
    override bool isFunction() const { return false; }
    
    override size_t size() const {
        if (declaration) {
            if (auto structDecl = cast(StructDecl)declaration) {
                if (structDecl.layoutComputed) {
                    return structDecl.structSize;
                }
            }
        }
        return 0;  // Layout not yet computed
    }
    
    override size_t alignment() const {
        if (declaration) {
            if (auto structDecl = cast(StructDecl)declaration) {
                if (structDecl.layoutComputed) {
                    return structDecl.structAlign;
                }
            }
        }
        return 1;  // Default alignment
    }
    
    override string toString() const {
        return name;
    }
}

/**
 * Mixin declaration: mixin(expression);
 * 
 * A compile-time string mixin that expands to D code.
 * The expression must evaluate to a string at compile time.
 * This is a placeholder that gets expanded during semantic analysis.
 */
class MixinDecl : Declaration {
    Expression mixinExpr;  // The expression that produces the string to mix in
    Declaration[] expandedDeclarations;  // Filled after CTFE expansion
    bool isExpanded;  // Whether expansion has been performed
    
    this(SourceLocation loc, Expression mixinExpr) {
        super(loc, "<mixin>", true);  // Mixins don't have a name
        this.mixinExpr = mixinExpr;
        this.isExpanded = false;
    }
    
    override string toString() const {
        if (isExpanded) {
            return format("MixinDecl(expanded: %d declarations)", expandedDeclarations.length);
        }
        return format("MixinDecl(%s)", mixinExpr.toString());
    }
}

/**
 * Static if declaration: static if (condition) { ... } else { ... }
 * 
 * A compile-time conditional that selects which declarations to include.
 * The condition is evaluated at compile time.
 * Unlike runtime if, the excluded branch is NOT type-checked.
 * This is a placeholder that gets expanded during semantic analysis.
 */
class StaticIfDecl : Declaration {
    Expression condition;          // The condition to evaluate at compile time
    Declaration[] thenDeclarations;  // Declarations in the then branch
    Declaration[] elseDeclarations;  // Declarations in the else branch (may be empty)
    Declaration[] expandedDeclarations;  // The selected declarations after expansion
    bool isExpanded;               // Whether expansion has been performed
    
    this(SourceLocation loc, Expression condition, 
         Declaration[] thenDecls, Declaration[] elseDecls = []) {
        super(loc, "<static if>", true);  // Static ifs don't have a name
        this.condition = condition;
        this.thenDeclarations = thenDecls;
        this.elseDeclarations = elseDecls;
        this.isExpanded = false;
    }
    
    override string toString() const {
        if (isExpanded) {
            return format("StaticIfDecl(expanded: %d declarations)", expandedDeclarations.length);
        }
        return format("StaticIfDecl(%s, then: %d decls, else: %d decls)", 
            condition.toString(), thenDeclarations.length, elseDeclarations.length);
    }
}