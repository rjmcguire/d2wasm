/**
 * Symbol Table for D-to-WASM Compiler
 * 
 * This module provides symbol resolution and scope management.
 * It tracks variables, functions, types, and their visibility across scopes.
 */
module semantic.symbol_table;

import ast.nodes;
import ast.statements;
import ast.expressions;
import std.string;
import std.array;
import std.algorithm;
import std.conv;
import std.stdio;

/**
 * Symbol kinds
 */
enum SymbolKind {
    Variable,
    Function,
    Type,
    Parameter,
    Field
}

/**
 * Symbol entry in the symbol table
 */
class Symbol {
    string name;
    SymbolKind kind;
    Type type;
    Declaration declaration;  // AST node that declares this symbol
    SourceLocation location;
    bool isGlobal;
    bool isConstant;  // True for manifest constants (enum X = ...)
    bool isCTFEOnly;  // True for compile-time-only functions (__writeln, __traits, etc.)
    bool isVariadic;  // True for variadic functions (__writeln, etc.)
    
    // Module path for this symbol (e.g., ["animals", "dog"])
    // Used for name mangling and multi-module disambiguation
    string[] modulePath;
    
    // For local variables/parameters: unique ID assigned by type checker
    uint uniqueLocalId = uint.max;  // uint.max = not a local variable
    
    this(string name, SymbolKind kind, Type type, Declaration decl, SourceLocation location, bool isGlobal = false) {
        this.name = name;
        this.kind = kind;
        this.type = type;
        this.declaration = decl;
        this.location = location;
        this.isGlobal = isGlobal;
    }
    
    /// Constructor with module path
    this(string name, SymbolKind kind, Type type, Declaration decl, SourceLocation location, 
         bool isGlobal, const(string[]) modulePath) {
        this(name, kind, type, decl, location, isGlobal);
        this.modulePath = modulePath.dup;
    }
    
    /**
     * Get the fully qualified name: "module.path.symbolName"
     */
    string fullyQualifiedName() const {
        if (modulePath.length == 0) {
            return name;
        }
        return modulePath.join(".") ~ "." ~ name;
    }
    
    override string toString() {
        string typeStr = type ? type.toString() : "<unknown>";
        return format("%s %s: %s", kind, name, typeStr);
    }
}

/**
 * Symbol scope for managing symbol visibility
 */
class Scope {
    Scope parent;
    Symbol[string] symbols;
    string name;  // For debugging
    uint[] declaredVars;  // Local IDs declared in this scope (for RAII unwind)

    this(Scope parent = null, string name = "anonymous") {
        this.parent = parent;
        this.name = name;
    }
    
    /**
     * Add symbol to this scope.
     * Rejects if symbol already exists in this scope OR if it shadows
     * a variable in an outer scope (shadowing is disallowed).
     */
    void addSymbol(Symbol symbol) {
        // Check current scope
        if (symbol.name in symbols) {
            throw new SemanticError(
                format("Symbol '%s' is already defined in scope '%s'", symbol.name, name),
                symbol.location
            );
        }
        
        // Check for shadowing in parent scopes (only for variables/parameters)
        if (symbol.kind == SymbolKind.Variable || symbol.kind == SymbolKind.Parameter) {
            if (auto outer = lookupOuter(symbol.name)) {
                if (outer.kind == SymbolKind.Variable || outer.kind == SymbolKind.Parameter) {
                    if (!outer.isConstant) {  // Allow shadowing manifest constants (enum x = ...)
                        throw new SemanticError(
                            format("Variable '%s' shadows outer variable declared at %s",
                                   symbol.name, outer.location.toString()),
                            symbol.location
                        );
                    }
                }
            }
        }
        
        symbols[symbol.name] = symbol;
    }
    
    /**
     * Look up symbol in parent scopes only (not this scope)
     */
    Symbol lookupOuter(string name) {
        if (parent) {
            return parent.lookup(name);
        }
        return null;
    }
    
    /**
     * Look up symbol in this scope only
     */
    Symbol lookupLocal(string name) {
        auto ptr = name in symbols;
        return ptr ? *ptr : null;
    }
    
    /**
     * Look up symbol in this scope and parent scopes
     */
    Symbol lookup(string name) {
        auto local = lookupLocal(name);
        if (local) {
            return local;
        }
        
        if (parent) {
            return parent.lookup(name);
        }
        
        return null;
    }
    
    /**
     * Get all symbols in this scope
     */
    Symbol[] getAllSymbols() {
        return symbols.values;
    }
    
    /**
     * Check if this is a global scope
     */
    bool isGlobal() {
        return parent is null;
    }
}

/**
 * Semantic analysis error
 */
class SemanticError : Exception {
    SourceLocation location;
    
    this(string message, SourceLocation location, string file = __FILE__, size_t line = __LINE__) {
        this.location = location;
        super(format("%s at %s", message, location.toString()), file, line);
    }
}

/**
 * Symbol table manager
 */
class SymbolTable {
    private Scope globalScope;
    private Scope currentScope;
    private Scope[] scopeStack;
    
    // Built-in methods registry: maps (typeKind, methodName) to FunctionDecl
    // typeKind is a string like "array", "string", etc.
    private FunctionDecl[string][string] builtinMethods;
    
    // Current module path for name mangling (e.g., ["animals", "dog"])
    // Set from ModuleDecl during compilation, empty if no module declaration
    private string[] _modulePath;
    
    // Lazy CTFE evaluation - callback set by CTFEEvaluator
    void delegate(ManifestConstantDecl) ctfeResolver;
    
    this() {
        globalScope = new Scope(null, "global");
        currentScope = globalScope;
    }
    
    /**
     * Set the current module path from a ModuleDecl.
     * Called during compilation setup.
     */
    void setModulePath(string[] path) {
        _modulePath = path.dup;
    }
    
    /**
     * Get the current module path.
     * Returns empty array if no module declaration present.
     */
    @property const(string[]) modulePath() const {
        return _modulePath;
    }
    
    /**
     * Get the fully qualified module name as a string.
     * Returns empty string if no module declaration present.
     */
    string moduleFullyQualifiedName() const {
        import std.array : join;
        return _modulePath.join(".");
    }
    
    /**
     * Lazily resolve a manifest constant's integer value via CTFE.
     * Call this instead of accessing ctfeValue directly.
     */
    long resolveManifestValue(ManifestConstantDecl manifest) {
        if (!manifest.ctfeComplete) {
            if (ctfeResolver is null) {
                throw new SemanticError("CTFE not configured - cannot resolve '" ~ manifest.name ~ "'", manifest.location);
            }
            ctfeResolver(manifest);
        }
        return manifest.ctfeValue;
    }
    
    /**
     * Lazily resolve a manifest constant's string value via CTFE.
     * Use for string enum constants.
     */
    string resolveManifestStringValue(ManifestConstantDecl manifest) {
        if (!manifest.ctfeComplete) {
            if (ctfeResolver is null) {
                throw new SemanticError("CTFE not configured - cannot resolve '" ~ manifest.name ~ "'", manifest.location);
            }
            ctfeResolver(manifest);
        }
        return manifest.ctfeStringValue;
    }
    
    /**
     * Ensure a manifest constant is evaluated (for either type).
     */
    void ensureManifestEvaluated(ManifestConstantDecl manifest) {
        if (!manifest.ctfeComplete) {
            if (ctfeResolver is null) {
                throw new SemanticError("CTFE not configured - cannot resolve '" ~ manifest.name ~ "'", manifest.location);
            }
            ctfeResolver(manifest);
        }
    }
    
    /**
     * Check if a manifest constant has been evaluated yet.
     */
    bool isManifestEvaluated(ManifestConstantDecl manifest) {
        return manifest.ctfeComplete;
    }
    
    /**
     * Register a built-in method for a type kind
     */
    void registerBuiltinMethod(string typeKind, string methodName, FunctionDecl method) {
        if (typeKind !in builtinMethods) {
            builtinMethods[typeKind] = (FunctionDecl[string]).init;
        }
        builtinMethods[typeKind][methodName] = method;
    }
    
    /**
     * Look up a built-in method for a type kind
     */
    FunctionDecl lookupBuiltinMethod(string typeKind, string methodName) {
        if (auto methods = typeKind in builtinMethods) {
            if (auto method = methodName in *methods) {
                return *method;
            }
        }
        return null;
    }
    
    // --- Per-function scope state (local ID allocation) ---

    /// Unique local ID counter — reset per function.
    uint nextLocalId;

    /// Allocate the next unique local ID (for variables/parameters).
    uint allocateLocalId() {
        return nextLocalId++;
    }

    // --- Per-scope variable tracking (RAII unwind) ---
    // Variable lists live on Scope.declaredVars — no parallel stack needed.

    /// Return the current scope's declared variable IDs (for destructOnExit).
    uint[] popScopeVars() {
        return currentScope.declaredVars;
    }

    /// Add a variable to the current scope's tracking list.
    void trackScopeVar(uint localId) {
        currentScope.declaredVars ~= localId;
    }

    /// Get the unwind chain from current scope up to the function scope (inclusive).
    /// Returns innermost scope first.
    uint[][] getUnwindChain() {
        import std.string : startsWith;
        uint[][] chain;
        Scope s = currentScope;
        while (s !is null) {
            chain ~= s.declaredVars.dup;
            if (s.name.startsWith("function:"))
                break;
            s = s.parent;
        }
        return chain;
    }

    // --- Scope state save/restore (for template instantiation) ---

    /// Saved scope state for temporary scope switching (e.g., template instantiation).
    struct ScopeState {
        Scope currentScope;
        Scope[] scopeStack;
        uint nextLocalId;
    }

    /// Save current scope state and reset to global scope.
    ScopeState saveAndResetScope() {
        auto saved = ScopeState(currentScope, scopeStack.dup, nextLocalId);
        currentScope = globalScope;
        scopeStack = null;
        nextLocalId = 0;
        return saved;
    }

    /// Restore a previously saved scope state.
    void restoreScope(ScopeState saved) {
        currentScope = saved.currentScope;
        scopeStack = saved.scopeStack;
        nextLocalId = saved.nextLocalId;
    }

    /**
     * Enter a new scope
     */
    void enterScope(string name = "block") {
        scopeStack ~= currentScope;
        currentScope = new Scope(currentScope, name);
    }
    
    /**
     * Exit current scope
     */
    void exitScope() {
        if (scopeStack.length == 0) {
            throw new SemanticError("Cannot exit global scope", SourceLocation());
        }
        
        currentScope = scopeStack[$-1];
        scopeStack = scopeStack[0..$-1];
    }
    
    /**
     * Add symbol to current scope
     */
    void addSymbol(Symbol symbol) {
        currentScope.addSymbol(symbol);
    }
    
    /**
     * Look up symbol starting from current scope.
     * For manifest constants, triggers lazy CTFE evaluation to ensure
     * the type is correct (e.g., string vs int).
     */
    Symbol lookupSymbol(string name) {
        auto symbol = currentScope.lookup(name);
        
        // For manifest constants, ensure CTFE has run so type is correct
        if (symbol && symbol.isConstant) {
            if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                if (!manifest.ctfeComplete && ctfeResolver !is null) {
                    // Trigger lazy evaluation
                    ctfeResolver(manifest);
                    // Update symbol type from inferred type
                    if (manifest.inferredType !is null) {
                        symbol.type = manifest.inferredType;
                    }
                }
            }
        }
        
        return symbol;
    }
    
    /**
     * Look up symbol in global scope only
     */
    Symbol lookupGlobalSymbol(string name) {
        return globalScope.lookupLocal(name);
    }
    
    /**
     * Get current scope
     */
    Scope getCurrentScope() {
        return currentScope;
    }
    
    /**
     * Get global scope
     */
    Scope getGlobalScope() {
        return globalScope;
    }
    
    /**
     * Check if we're in global scope
     */
    bool inGlobalScope() {
        return currentScope == globalScope;
    }
    
    /**
     * Add built-in symbols (basic types, functions)
     */
    void addBuiltinSymbols() {
        auto loc = SourceLocation("<builtin>", 1, 1, 0, 0);
        
        // Basic types
        addBuiltinType("void", BasicType.Kind.Void, loc);
        addBuiltinType("bool", BasicType.Kind.Bool, loc);
        addBuiltinType("byte", BasicType.Kind.Int8, loc);
        addBuiltinType("short", BasicType.Kind.Int16, loc);
        addBuiltinType("int", BasicType.Kind.Int32, loc);
        addBuiltinType("long", BasicType.Kind.Int64, loc);
        addBuiltinType("ubyte", BasicType.Kind.UInt8, loc);
        addBuiltinType("ushort", BasicType.Kind.UInt16, loc);
        addBuiltinType("uint", BasicType.Kind.UInt32, loc);
        addBuiltinType("ulong", BasicType.Kind.UInt64, loc);
        addBuiltinType("float", BasicType.Kind.Float32, loc);
        addBuiltinType("double", BasicType.Kind.Float64, loc);
        addBuiltinType("char", BasicType.Kind.Char, loc);
        
        // Builtin functions
        addBuiltinFunction("writeln", loc, false, true);  // Runtime, variadic
        
        // CTFE-only builtins (only available at compile time)
        addBuiltinFunction("__writeln", loc, true, true);  // CTFE-only, variadic
        
        // CTFE print intrinsics - typed variants (all become WASM imports)
        auto i32Type = new BasicType(loc, BasicType.Kind.Int32);
        auto voidType = new BasicType(loc, BasicType.Kind.Void);
        
        // __ctfe_print_i32: void(int) - standalone debug, prints "CTFE: <value>\n"
        auto printI32Type = new FunctionType(loc, voidType, [i32Type]);
        auto printI32Symbol = new Symbol("__ctfe_print_i32", SymbolKind.Function, printI32Type, null, loc, true);
        printI32Symbol.isCTFEOnly = true;
        globalScope.addSymbol(printI32Symbol);
        
        // Building blocks for __writeln lowering (no prefix, no automatic newline)
        
        // __ctfe_write_i32: void(int)
        auto writeI32Type = new FunctionType(loc, voidType, [i32Type]);
        auto writeI32Symbol = new Symbol("__ctfe_write_i32", SymbolKind.Function, writeI32Type, null, loc, true);
        writeI32Symbol.isCTFEOnly = true;
        globalScope.addSymbol(writeI32Symbol);
        
        // __ctfe_write_str: void(ptr: i32, len: i32) - string from memory
        auto writeStrType = new FunctionType(loc, voidType, [i32Type, i32Type]);
        auto writeStrSymbol = new Symbol("__ctfe_write_str", SymbolKind.Function, writeStrType, null, loc, true);
        writeStrSymbol.isCTFEOnly = true;
        globalScope.addSymbol(writeStrSymbol);
        
        // __ctfe_write_bool: void(int) - prints "true" or "false"
        auto writeBoolType = new FunctionType(loc, voidType, [i32Type]);
        auto writeBoolSymbol = new Symbol("__ctfe_write_bool", SymbolKind.Function, writeBoolType, null, loc, true);
        writeBoolSymbol.isCTFEOnly = true;
        globalScope.addSymbol(writeBoolSymbol);
        
        // __ctfe_write_newline: void() - emits newline
        auto writeNewlineType = new FunctionType(loc, voidType, []);
        auto writeNewlineSymbol = new Symbol("__ctfe_write_newline", SymbolKind.Function, writeNewlineType, null, loc, true);
        writeNewlineSymbol.isCTFEOnly = true;
        globalScope.addSymbol(writeNewlineSymbol);
        
        // Register built-in methods for array/slice types
        registerArrayBuiltinMethods(loc);
    }
    
    /**
     * Register built-in methods for array/slice types
     */
    private void registerArrayBuiltinMethods(SourceLocation loc) {
        auto intType = new BasicType(loc, BasicType.Kind.Int32);
        auto voidType = new BasicType(loc, BasicType.Kind.Void);
        
        // opIndex: (size_t index) -> elementType
        // For now, we use int for index and return type (element type is dynamic)
        auto elementType = new BasicType(loc, BasicType.Kind.Int32);  // Generic, actual type determined at call site
        
        Parameter[] indexParams = [Parameter(intType, "index", null)];
        auto opIndex = new FunctionDecl(loc, "opIndex", elementType, indexParams, null);
        opIndex.isMethod = true;
        opIndex.isIntrinsic = true;
        registerBuiltinMethod("array", "opIndex", opIndex);
        
        // reserve: (size_t newCapacity) -> void
        // Ensures the array has at least newCapacity capacity
        Parameter[] reserveParams = [Parameter(intType, "newCapacity", null)];
        auto reserve = new FunctionDecl(loc, "reserve", voidType, reserveParams, null);
        reserve.isMethod = true;
        reserve.isIntrinsic = true;
        registerBuiltinMethod("array", "reserve", reserve);
    }
    
    /**
     * Helper to add built-in type
     */
    private void addBuiltinType(string name, BasicType.Kind kind, SourceLocation loc) {
        auto type = new BasicType(loc, kind);
        auto symbol = new Symbol(name, SymbolKind.Type, type, null, loc, true);
        globalScope.addSymbol(symbol);
    }
    
    /**
     * Helper to add built-in function
     */
    private void addBuiltinFunction(string name, SourceLocation loc, bool isCTFEOnly = false, bool isVariadic = false) {
        // Create a function type for writeln - it's variadic but we'll simplify it
        // Parameters: variadic (accepts any number of arguments)
        // Return type: void
        auto returnType = new BasicType(loc, BasicType.Kind.Void);
        
        // For now, create a simple function type that can accept any arguments
        // In a complete implementation, this would be more sophisticated
        Type[] paramTypes = []; // Empty parameter list - writeln is variadic
        auto funcType = new FunctionType(loc, returnType, paramTypes);
        auto symbol = new Symbol(name, SymbolKind.Function, funcType, null, loc, true);
        symbol.isCTFEOnly = isCTFEOnly;
        symbol.isVariadic = isVariadic;
        globalScope.addSymbol(symbol);
    }
    
    /**
     * Debug: Print symbol table contents
     */
    void debugPrint() {
        writeln("=== Symbol Table ===");
        debugPrintScope(globalScope, 0);
    }
    
    private void debugPrintScope(Scope scope_, int depth) {
        string indent = replicate("  ", depth);
        writeln(format("%sScope: %s", indent, scope_.name));
        
        foreach (symbol; scope_.symbols.values) {
            writeln(format("%s  %s", indent, symbol.toString()));
        }
        
        // Note: We don't recurse into child scopes here since we don't track them
        // This is a simplified implementation focused on current scope traversal
    }
}

/**
 * Symbol collector visitor - first pass to collect all symbols
 */
class SymbolCollector {
    private SymbolTable symbolTable;
    
    this(SymbolTable symbolTable) {
        this.symbolTable = symbolTable;
    }
    
    /**
     * Collect symbols from declaration list
     */
    void collectSymbols(Declaration[] declarations) {
        foreach (decl; declarations) {
            collectSymbol(decl);
        }
    }
    
    /**
     * Collect symbol from single declaration
     */
    void collectSymbol(Declaration decl) {
        if (auto funcDecl = cast(FunctionDecl)decl) {
            collectFunctionSymbol(funcDecl);
        } else if (auto importedFunc = cast(ImportedFunctionDecl)decl) {
            collectImportedFunctionSymbol(importedFunc);
        } else if (auto classDecl = cast(ClassDecl)decl) {
            collectClassSymbol(classDecl);
        } else if (auto ifaceDecl = cast(InterfaceDecl)decl) {
            collectInterfaceSymbol(ifaceDecl);
        } else if (auto structDecl = cast(StructDecl)decl) {
            collectStructSymbol(structDecl);
        } else if (auto varDecl = cast(VariableDecl)decl) {
            collectVariableSymbol(varDecl);
        } else if (auto enumDecl = cast(EnumDecl)decl) {
            collectEnumSymbol(enumDecl);
        } else if (auto manifestDecl = cast(ManifestConstantDecl)decl) {
            collectManifestConstant(manifestDecl);
        }
    }
    
    private void collectFunctionSymbol(FunctionDecl decl) {
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Function,
            new FunctionType(decl.location, decl.returnType, getFunctionParameterTypes(decl)),
            decl,
            decl.location,
            symbolTable.inGlobalScope(),
            symbolTable.modulePath
        );
        symbolTable.addSymbol(symbol);
    }
    
    private void collectImportedFunctionSymbol(ImportedFunctionDecl decl) {
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Function,
            new FunctionType(decl.location, decl.returnType, getImportedFunctionParameterTypes(decl)),
            decl,
            decl.location,
            true,  // Imported functions are always global
            symbolTable.modulePath
        );
        symbolTable.addSymbol(symbol);
    }
    
    private void collectClassSymbol(ClassDecl decl) {
        // First, resolve base class if present (needed for layout inheritance)
        if (decl.baseClass && !decl.baseClassDecl) {
            if (auto userType = cast(UserType)decl.baseClass) {
                auto typeSymbol = symbolTable.lookupSymbol(userType.name);
                if (typeSymbol && typeSymbol.kind == SymbolKind.Type) {
                    if (auto baseClassDecl = cast(ClassDecl)typeSymbol.declaration) {
                        decl.baseClassDecl = baseClassDecl;
                        userType.declaration = baseClassDecl;
                    }
                }
            }
        }
        
        // Compute class layout (with vtable pointer as first field)
        // Default to 4-byte pointers (wasm32)
        computeClassLayout(decl, 4);
        
        auto userType = new UserType(decl.location, decl.name);
        userType.declaration = decl;  // Link type to declaration for size lookup
        
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Type,
            userType,
            decl,
            decl.location,
            symbolTable.inGlobalScope(),
            symbolTable.modulePath
        );
        symbolTable.addSymbol(symbol);
    }
    
    private void collectInterfaceSymbol(InterfaceDecl decl) {
        auto userType = new UserType(decl.location, decl.name);
        userType.declaration = decl;  // Link type to declaration
        
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Type,
            userType,
            decl,
            decl.location,
            symbolTable.inGlobalScope(),
            symbolTable.modulePath
        );
        symbolTable.addSymbol(symbol);
    }
    
    private void collectStructSymbol(StructDecl decl) {
        // Compute struct layout
        computeStructLayout(decl);
        
        auto userType = new UserType(decl.location, decl.name);
        userType.declaration = decl;  // Link type to declaration for size lookup
        
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Type,
            userType,
            decl,
            decl.location,
            symbolTable.inGlobalScope(),
            symbolTable.modulePath
        );
        symbolTable.addSymbol(symbol);
    }
    
    /**
     * Compute struct layout: field offsets, alignment, and total size
     */
    /**
     * Compute field layout for an aggregate type (struct or class).
     * Iterates over members, resolves nested types, computes offsets/alignment.
     *
     * Returns: tuple of (finalOffset, maxAlignment)
     */
    private void computeFieldLayout(AggregateDecl decl, size_t startOffset, size_t startAlign) {
        size_t currentOffset = startOffset;
        size_t maxAlign = startAlign;

        foreach (member; decl.members) {
            if (auto varDecl = cast(VariableDecl)member) {
                // For UserType fields, resolve and ensure nested layout is computed
                if (auto userType = cast(UserType)varDecl.type) {
                    if (!userType.declaration) {
                        auto sym = symbolTable.lookupSymbol(userType.name);
                        if (sym && sym.kind == SymbolKind.Type) {
                            userType.declaration = sym.declaration;
                        }
                    }
                    // Ensure nested aggregate layout is computed
                    if (auto nested = cast(AggregateDecl)userType.declaration) {
                        if (!nested.layoutComputed) {
                            computeAggregateLayout(nested);
                        }
                    }
                }

                size_t fieldSize = varDecl.type ? varDecl.type.size() : 4;
                size_t fieldAlign = varDecl.type ? varDecl.type.alignment() : 4;

                // Align current offset to field's alignment requirement
                if (fieldAlign > 0) {
                    currentOffset = (currentOffset + fieldAlign - 1) & ~(fieldAlign - 1);
                }

                // Record field info
                StructField field;
                field.name = varDecl.name;
                field.type = varDecl.type;
                field.offset = currentOffset;
                field.size = fieldSize;
                field.alignment = fieldAlign;
                decl.fields ~= field;

                if (fieldAlign > maxAlign) maxAlign = fieldAlign;
                currentOffset += fieldSize;
            }
        }

        // Pad to alignment
        if (maxAlign > 0) {
            currentOffset = (currentOffset + maxAlign - 1) & ~(maxAlign - 1);
        }

        decl.aggregateSize_ = currentOffset;
        decl.aggregateAlign_ = maxAlign;
        decl.layoutComputed = true;
    }

    /**
     * Dispatch to struct or class layout computation.
     */
    private void computeAggregateLayout(AggregateDecl decl) {
        if (decl.layoutComputed) return;
        if (auto sd = cast(StructDecl)decl) {
            computeStructLayout(sd);
        } else if (auto cd = cast(ClassDecl)decl) {
            computeClassLayout(cd);
        }
    }

    private void computeStructLayout(StructDecl decl) {
        if (decl.layoutComputed) return;
        computeFieldLayout(decl, 0, 1);
    }

    /**
     * Compute class layout: field offsets, alignment, and total size.
     *
     * Class layout differs from struct layout:
     * - Implicit vtable pointer as first field
     * - For derived classes: base class fields come first
     * - Derived fields start after base class fields
     *
     * Params:
     *   decl = Class declaration to compute layout for
     *   pointerSize = Size of pointers (4 for wasm32, 8 for wasm64/native)
     */
    private void computeClassLayout(ClassDecl decl, size_t pointerSize = 4) {
        if (decl.layoutComputed) return;

        size_t startOffset;
        size_t startAlign;

        // If we have a base class, inherit its layout
        if (decl.baseClassDecl) {
            if (!decl.baseClassDecl.layoutComputed) {
                computeClassLayout(decl.baseClassDecl, pointerSize);
            }
            // Inherit base class fields (including vtable_ptr)
            decl.fields = decl.baseClassDecl.fields.dup;
            startOffset = decl.baseClassDecl.classSize;
            startAlign = decl.baseClassDecl.classAlign;
        } else {
            // No base class - start with vtable pointer
            startOffset = pointerSize;
            startAlign = pointerSize;
        }

        computeFieldLayout(decl, startOffset, startAlign);
    }
    
    private void collectVariableSymbol(VariableDecl decl) {
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Variable,
            decl.type,
            decl,
            decl.location,
            symbolTable.inGlobalScope(),
            symbolTable.modulePath
        );
        symbolTable.addSymbol(symbol);
    }
    
    private void collectEnumSymbol(EnumDecl decl) {
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Type,
            new UserType(decl.location, decl.name),
            decl,
            decl.location,
            symbolTable.inGlobalScope(),
            symbolTable.modulePath
        );
        symbolTable.addSymbol(symbol);
    }
    
    private void collectManifestConstant(ManifestConstantDecl decl) {
        // Use the inferred type if CTFE has already evaluated it, 
        // otherwise default to Int32 (will be updated later if needed)
        Type symbolType;
        if (decl.ctfeComplete && decl.inferredType !is null) {
            symbolType = decl.inferredType;
        } else {
            symbolType = new BasicType(decl.location, BasicType.Kind.Int32);
        }
        
        auto symbol = new Symbol(
            decl.name,
            SymbolKind.Variable,  // Manifest constants are like compile-time variables
            symbolType,
            decl,
            decl.location,
            symbolTable.inGlobalScope(),
            symbolTable.modulePath
        );
        symbol.isConstant = true;  // Mark as constant
        symbolTable.addSymbol(symbol);
    }
    
    private Type[] getFunctionParameterTypes(FunctionDecl decl) {
        Type[] types;
        foreach (param; decl.parameters) {
            types ~= param.type;
        }
        return types;
    }
    
    private Type[] getImportedFunctionParameterTypes(ImportedFunctionDecl decl) {
        Type[] types;
        foreach (param; decl.parameters) {
            types ~= param.type;
        }
        return types;
    }
}