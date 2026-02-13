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
import semantic.symbol_table : SymbolTable, SymbolKind;

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
    string sourceText;  // reference to original source (D slice, not a copy)

    this(SourceLocation loc) {
        location = loc;
    }

    /// Get this node's original source text.
    string getSourceText() const {
        if (sourceText && location.startOffset < sourceText.length && location.endOffset <= sourceText.length)
            return sourceText[location.startOffset .. location.endOffset];
        return null;
    }
    
    // TODO: Add visitor pattern support later
    abstract override string toString() const;
}

// TODO: Add visitor pattern support in a future iteration

/// Visibility levels for declarations
enum Visibility : ubyte {
    default_,    // D's default (public at module scope)
    private_,
    package_,
    protected_,
    public_,
    export_,
}

/// Attribute flags for declarations, packed into a uint via bitfields.
/// Not all flags are meaningful for all declaration kinds.
struct DeclAttrs {
    mixin(bitfields!(
        // Storage classes
        bool, "isStatic_",    1,
        bool, "isExtern",     1,
        bool, "isFinal",      1,
        bool, "isAbstract",   1,
        bool, "isOverride",   1,
        bool, "isDeprecated", 1,
        // Type qualifiers
        bool, "isConst",      1,
        bool, "isImmutable",  1,
        bool, "isShared",     1,
        bool, "isGshared",    1,
        // Function attributes
        bool, "isNogc",       1,
        bool, "isNothrow",    1,
        bool, "isPure",       1,
        bool, "isSafe",       1,
        bool, "isTrusted",    1,
        bool, "isSystem",     1,
        bool, "isProperty_",  1,
        bool, "isDisable",    1,
        uint, "",             14, // padding to fill 32 bits
    ));

    /// Merge another DeclAttrs into this one (OR all flags)
    void merge(DeclAttrs other) {
        (cast(uint*)&this)[0] |= (cast(const uint*)&other)[0];
    }
}

/**
 * Abstract base for all declaration nodes
 */
abstract class Declaration : ASTNode {
    string name;
    Visibility visibility = Visibility.default_;
    DeclAttrs attrs;

    /// Dependencies from static if conditions that produced this declaration.
    /// Used for incremental compilation - if these symbols change, this decl
    /// must be recompiled even if its own source hasn't changed.
    string[] staticIfDependencies;

    this(SourceLocation loc, string name, bool isPublic = false) {
        super(loc);
        this.name = name;
        if (isPublic)
            this.visibility = Visibility.public_;
    }

    /// Backward-compatible property
    @property bool isPublic() const {
        return visibility == Visibility.public_ || visibility == Visibility.default_;
    }

    @property void isPublic(bool val) {
        visibility = val ? Visibility.public_ : Visibility.default_;
    }
}

/**
 * Module declaration: module foo.bar.baz;
 * 
 * Stores the module path as an array of identifiers.
 * If no module declaration is present, the path defaults to the filename.
 */
class ModuleDecl : Declaration {
    /// Module path components: ["foo", "bar", "baz"] for module foo.bar.baz;
    string[] modulePath;
    
    this(SourceLocation loc, string[] modulePath) {
        // The full module name is the last component (or joined path)
        string moduleName = modulePath.length > 0 ? modulePath[$ - 1] : "";
        super(loc, moduleName, true);  // Module names are always public
        this.modulePath = modulePath;
    }
    
    /// Get the fully qualified module name: "foo.bar.baz"
    string fullyQualifiedName() const {
        import std.array : join;
        return modulePath.join(".");
    }
    
    override string toString() const {
        return format("module %s;", fullyQualifiedName());
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
    
    /// Is this an aggregate type (struct, class, static array)?
    /// Aggregates are passed by address, not by value.
    bool isAggregate() const {
        return false;  // Override in aggregate types
    }

    /// Returns the StructDecl if this type resolves to a struct, null otherwise.
    StructDecl asStruct() { return null; }

    /// Returns the ClassDecl if this type resolves to a class, null otherwise.
    ClassDecl asClass() { return null; }

    /// Returns the InterfaceDecl if this type resolves to an interface, null otherwise.
    InterfaceDecl asInterface() { return null; }

    /// True if this type is passed/returned via hidden pointer (struct, static array).
    bool isLargeReturn() const { return false; }

    /// Aggregate byte size (struct size, class size, static array total size), or 0.
    size_t aggregateSize() const { return 0; }

    /// Aggregate alignment, or 1.
    size_t aggregateAlignment() const { return 1; }

    /// Resolve through TemplateParamType wrappers to the underlying concrete type.
    /// Returns `this` for all types except TemplateParamType, which returns boundType.
    Type resolve() { return this; }
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

    // Function kind flags (packed into a single byte)
    // Note: isStatic and isProperty are forwarded to Declaration.attrs
    mixin(bitfields!(
        bool, "isMethod",      1,  // belongs to struct/class, has implicit `this`
        bool, "isCTFE",        1,  // CTFE-only function
        bool, "isIntrinsic",   1,  // compiler emits inline code instead of call
        bool, "isTypeChecked", 1,  // already type-checked (avoid redundant passes)
        bool, "isDestructor",  1,  // ~this() destructor
        bool, "isConstructor", 1,  // this() constructor
        bool, "needsArena",    1,  // allocates (directly or transitively), needs __arena param
        uint, "",              1,  // padding
    ));

    // Forward isStatic/isProperty to DeclAttrs on Declaration base
    @property bool isStatic() const { return attrs.isStatic_; }
    @property void isStatic(bool v) { attrs.isStatic_ = v; }
    @property bool isProperty() const { return attrs.isProperty_; }
    @property void isProperty(bool v) { attrs.isProperty_ = v; }

    Declaration parent;  // enclosing struct/class, null for free functions
    string mangledName;  // D ABI mangled name, set during emitter collection

    TemplateParamType[] templateParams;  // empty for non-template functions
    @property bool isTemplate() const { return templateParams.length > 0; }

    this(SourceLocation loc, string name, Type returnType,
         Parameter[] parameters, Statement body_,
         string[] attributes = [], bool isPublic = false) {
        super(loc, name, isPublic);
        this.returnType = returnType;
        this.parameters = parameters;
        this.body_ = body_;
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
    
    // Assigned by type checker - unique ID for this parameter
    uint uniqueLocalId = uint.max;  // uint.max = unassigned
    
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
 * Common base for struct and class declarations (aggregate types with fields).
 */
abstract class AggregateDecl : Declaration {
    Declaration[] members;
    StructField[] fields;
    size_t aggregateSize_;
    size_t aggregateAlign_;
    bool layoutComputed;
    FunctionDecl destructor;
    string[] aliasThis;  // alias-this member names (multi-alias)

    this(SourceLocation loc, string name, bool isPublic) {
        super(loc, name, isPublic);
    }

    StructField* getField(string fieldName) {
        foreach (ref field; fields) {
            if (field.name == fieldName) return &field;
        }
        return null;
    }

    bool hasDestructor() const {
        return destructor !is null;
    }
}

/**
 * Class declaration: class Name : BaseClass, Interface { members }
 *
 * Memory layout:
 *   [vtable_ptr][base_fields][derived_fields]
 *
 * The vtable_ptr is an implicit first field pointing to the class's vtable.
 */
class ClassDecl : AggregateDecl {
    Type baseClass;  // null if no inheritance (implicitly inherits Object)
    Type[] interfaces;

    // Resolved base class (set during type checking)
    ClassDecl baseClassDecl;

    // Constructor (if present)
    FunctionDecl constructor;

    // Virtual methods for vtable (populated during semantic analysis)
    FunctionDecl[] virtualMethods;

    // Backward-compat aliases
    alias classSize = aggregateSize_;
    alias classAlign = aggregateAlign_;

    // vtable index for this class (assigned during codegen)
    int vtableIndex = -1;

    // Packed vtable_ptr design:
    // vtable_ptr = (typeId << 16) | tableBase
    uint typeId = 0;       // Unique type ID for this class (for RTTI/error messages)
    uint tableBase = 0;    // Starting index in WASM function table

    // Interface tables: interface name -> table base index
    uint[string] itableBases;

    // TypeInfo offset in data section (for error messages, indexed by typeId)
    uint typeInfoOffset = 0;

    this(SourceLocation loc, string name, Type baseClass, Type[] interfaces,
         Declaration[] members, bool isPublic = false) {
        super(loc, name, isPublic);
        this.baseClass = baseClass;
        this.interfaces = interfaces;
        this.members = members;
    }

    /**
     * Check if this class has any virtual methods
     */
    bool hasVirtualMethods() const {
        return virtualMethods.length > 0;
    }

    override string toString() const {
        return format("ClassDecl(%s, size=%d, vtable=%d methods)",
                      name, classSize, virtualMethods.length);
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
class StructDecl : AggregateDecl {
    // Backward-compat aliases
    alias structSize = aggregateSize_;
    alias structAlign = aggregateAlign_;

    this(SourceLocation loc, string name, Declaration[] members, bool isPublic = false) {
        super(loc, name, isPublic);
        this.members = members;
    }

    override string toString() const {
        return format("StructDecl(%s, size=%d, align=%d%s)", name, structSize, structAlign,
                      destructor ? ", has ~this" : "");
    }
}

/**
 * Template declaration: wraps templated functions, structs, etc.
 * Both `T max(T)(T a, T b) { ... }` and `struct Pair(T, U) { ... }` desugar to this.
 */
class TemplateDecl : Declaration {
    TemplateParamType[] templateParams;
    Declaration[] members;
    Expression constraint;  // template constraint, e.g. __traits(isArithmetic, T)

    this(SourceLocation loc, string name, TemplateParamType[] templateParams,
         Declaration[] members, Expression constraint = null) {
        super(loc, name, false);
        this.templateParams = templateParams;
        this.members = members;
        this.constraint = constraint;
    }

    /// Eponymous member — has the same name as the template
    Declaration eponymousMember() {
        foreach (m; members)
            if (m.name == this.name) return m;
        return null;
    }

    override string toString() const {
        return format("TemplateDecl(%s, %d params, %d members)", name, templateParams.length, members.length);
    }
}

/**
 * Interface declaration: interface Name : ParentInterfaces { methods }
 */
class InterfaceDecl : Declaration {
    Type[] parentInterfaces;
    FunctionDecl[] methods;
    
    // Packed itable_ptr design (same as class vtable_ptr):
    // itable_ptr = (typeId << 16) | itableBase
    uint typeId = 0;       // Unique type ID for this interface (for RTTI/error messages)
    
    // TypeInfo offset in data section (for error messages, indexed by typeId)
    uint typeInfoOffset = 0;
    
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

    // WASM global index for scalar globals (int, bool, etc.)
    uint wasmGlobalIndex = uint.max;  // uint.max = not a scalar global
    
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
    bool ctfeInProgress;     // True while CTFE evaluation is running (cycle detection)
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

/**
 * Type alias: alias Name = Type;
 * Transparent — Name becomes another name for Type with no runtime distinction.
 */
class AliasDecl : Declaration {
    Type targetType;

    this(SourceLocation loc, string name, Type targetType) {
        super(loc, name, true);
        this.targetType = targetType;
    }

    override string toString() const {
        return format("AliasDecl(%s = %s)", name, targetType.toString());
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

    /// True if this is a fixed-size array (has explicit size), false for dynamic/slices
    @property bool isStaticArray() const { return arraySize !is null; }

    /// Arrays (both static and dynamic/slices) are aggregates
    override bool isAggregate() const { return true; }

    /// Static arrays are large returns (passed via hidden pointer)
    override bool isLargeReturn() const {
        return arraySize !is null;
    }
    
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
    Type[] templateArgs;  // Non-null for Pair!(int, string) in type position

    this(SourceLocation loc, string name) {
        super(loc);
        this.name = name;
    }

    /// Resolve this UserType's declaration from the symbol table if not already linked.
    /// Uses lookupGlobalSymbol to avoid triggering CTFE evaluation.
    void ensureResolved(SymbolTable symTab) {
        if (declaration is null) {
            auto sym = symTab.lookupGlobalSymbol(name);
            if (sym && sym.kind == SymbolKind.Type)
                declaration = sym.declaration;
        }
        if (declaration is null) {
            import semantic.symbol_table : SemanticError;
            throw new SemanticError(
                "Unknown type '" ~ name ~ "'",
                location);
        }
    }

    override bool isBasicType() const { return false; }
    override bool isPointer() const { return false; }
    override bool isArray() const { return false; }
    override bool isFunction() const { return false; }

    /// Structs and classes are aggregates (passed by address)
    override bool isAggregate() const {
        if (declaration) {
            return cast(StructDecl)declaration !is null ||
                   cast(ClassDecl)declaration !is null;
        }
        return false;
    }

    override StructDecl asStruct() {
        return cast(StructDecl)declaration;
    }

    override ClassDecl asClass() {
        return cast(ClassDecl)declaration;
    }

    override InterfaceDecl asInterface() {
        return cast(InterfaceDecl)declaration;
    }

    override bool isLargeReturn() const {
        return cast(StructDecl)declaration !is null;
    }

    override size_t aggregateSize() const {
        return size();
    }

    override size_t aggregateAlignment() const {
        return alignment();
    }

    override size_t size() const {
        if (declaration) {
            if (auto aggr = cast(AggregateDecl)declaration) {
                if (aggr.layoutComputed) {
                    return aggr.aggregateSize_;
                }
            }
            // Interface refs are fat pointers: {obj_ptr, itable_ptr} = 8 bytes
            if (cast(InterfaceDecl)declaration) {
                return 8;
            }
        }
        return 0;  // Layout not yet computed
    }

    override size_t alignment() const {
        if (declaration) {
            if (auto aggr = cast(AggregateDecl)declaration) {
                if (aggr.layoutComputed) {
                    return aggr.aggregateAlign_;
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
 * Template parameter type: a mutable type node that delegates to its bound type.
 *
 * All references to T in a template body share one TemplateParamType instance.
 * When bound (boundType != null), all Type methods delegate transparently.
 */
class TemplateParamType : Type {
    string paramName;
    Type boundType;

    this(SourceLocation loc, string paramName) {
        super(loc);
        this.paramName = paramName;
    }

    override bool isBasicType() const { return boundType ? boundType.isBasicType() : false; }
    override bool isPointer() const   { return boundType ? boundType.isPointer() : false; }
    override bool isArray() const     { return boundType ? boundType.isArray() : false; }
    override bool isFunction() const  { return boundType ? boundType.isFunction() : false; }
    override size_t size() const      { return boundType ? boundType.size() : 0; }
    override size_t alignment() const { return boundType ? boundType.alignment() : 0; }
    override bool isAggregate() const { return boundType ? boundType.isAggregate() : false; }
    override bool isLargeReturn() const { return boundType ? boundType.isLargeReturn() : false; }

    override StructDecl asStruct()       { return boundType ? boundType.asStruct() : null; }
    override ClassDecl asClass()         { return boundType ? boundType.asClass() : null; }
    override InterfaceDecl asInterface() { return boundType ? boundType.asInterface() : null; }

    override string toString() const {
        return boundType ? boundType.toString() : paramName;
    }

    override Type resolve() { return boundType ? boundType.resolve() : this; }
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

class StaticAssertDecl : Declaration {
    Expression condition;    // The condition to evaluate at compile time
    Expression message;      // Optional error message (may be null)
    bool isChecked;          // Whether this has been evaluated
    
    this(SourceLocation loc, Expression condition, Expression message = null) {
        super(loc, "<static assert>", true);
        this.condition = condition;
        this.message = message;
        this.isChecked = false;
    }
    
    override string toString() const {
        if (message !is null) {
            return format("StaticAssertDecl(%s, %s)", condition.toString(), message.toString());
        }
        return format("StaticAssertDecl(%s)", condition.toString());
    }
}