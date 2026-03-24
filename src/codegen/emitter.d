/**
 * Binary WASM Emitter - Automata Style
 * 
 * This module implements direct binary WebAssembly emission from the AST.
 * It follows an automata pattern where each compilation phase is a distinct
 * state with clear inputs and outputs.
 * 
 * Phases:
 *   1. Collect - Gather all declarations, build indices
 *   2. Types   - Emit type section (function signatures)
 *   3. Funcs   - Emit function section (type indices)
 *   4. Memory  - Emit memory section (if needed)
 *   5. Exports - Emit export section
 *   6. Code    - Emit code section (function bodies)
 *   7. Data    - Emit data section (array literals, etc.)
 */
module codegen.emitter;

import codegen.wasm.types;
import codegen.wasm.func_context : FuncContext;
import codegen.wasm.sections;
import codegen.target : WasmVtablePacking, sliceInfo;
import codegen.param_layout;
import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;
import semantic.modules_context : ModulesContext;
import cache.entry : SourceHash, CacheEntry;

import std.array : Appender, array;
import std.algorithm : map, canFind;
import std.conv : to;
import std.format : format;
import std.digest.murmurhash;

// Re-export section types used externally
public import codegen.wasm.sections : FuncSig, ImportInfo;

//==============================================================================
// Error Handling
//==============================================================================

class EmitError : Exception {
    SourceLocation location;

    this(string msg, SourceLocation loc, string file = __FILE__, size_t line = __LINE__) {
        this.location = loc;
        super(msg, file, line);
    }
}

//==============================================================================
// Function Signature - imported from codegen.wasm.sections
//==============================================================================

//==============================================================================
// Collected Function Info
//==============================================================================

struct FuncInfo {
    import ast.expressions : FunctionLiteralExpression;
    string name;        // Mangled name (funcIndex key)
    string exportName;  // Bare name for WASM export (null = use name)
    uint typeIndex;
    FunctionDecl decl;
    bool exported;
    bool isImport;
    StructDecl structParent;  // Non-null for struct methods
    ClassDecl classParent;    // Non-null for class methods
    ParamLayout paramLayout;  // Canonical parameter layout
    FunctionLiteralExpression lambdaExpr;  // Non-null for lifted lambdas (capture info)
}

//==============================================================================
// Imported Function Info - imported from codegen.wasm.sections
//==============================================================================

//==============================================================================
// Emitter State
//==============================================================================

enum EmitPhase {
    init,
    collecting,
    emittingTypes,
    emittingFunctions,
    emittingMemory,
    emittingExports,
    emittingCode,
    emittingData,
    done,
    error,
}

//==============================================================================
// Binary Emitter
//==============================================================================

class BinaryEmitter {
    // Package-visible for FuncContext access
    package {
        FuncSig[] types;
        FuncInfo[] functions;
        uint[string] funcIndex;
        ImportInfo[] imports;
        uint[string] importIndex;
        uint concatFuncIndex;
        SymbolTable symbolTable;
        uint spGlobal;
        uint callStackDepthGlobal;  // Global for call stack depth (milestone 144)
        bool needsArraySupport;
        bool[string] neededCTFEImports;
        bool ctfeMode;  // When true, compile CTFE-only functions (don't skip them)
        bool enableStackTrace;  // Stack trace option (milestone 144)

        // Arena built-in functions
        bool hasArenaBuiltins = false;
        uint arenaAllocFuncIndex;
        uint arenaNewFuncIndex;
        uint arenaDropFuncIndex;
        uint arenaBaseGlobal;        // Index of $arena_base global
        uint arenaWatermarkGlobal;   // Index of $arena_wm_top global (watermark stack pointer)

        // Exception handling globals and slot array
        uint exceptionPendingGlobal;  // Index of __exception_pending global
        uint exceptionDepthGlobal;    // Index of __exception_depth global
        uint exceptionArrayOffset;    // Memory offset of pre-allocated exception slot array
    }
    
    /// FFI ArgKind — matches the C enum in ffi_trampoline.c
    package enum ArgKind : ubyte {
        ARG_I32    = 0,
        ARG_I64    = 1,
        ARG_F32    = 2,
        ARG_F64    = 3,
        ARG_PTR    = 4,
        RET_VOID   = 5,
        RET_STRUCT = 6,
    }

    /// FFI metadata for one imported function
    package struct FFIMeta {
        string name;
        ArgKind retKind;
        ArgKind[] paramKinds;
        string nativeName;  // if set, dlsym uses this instead of name (for objc_msgSend aliasing)
        // Struct return metadata (only valid when retKind == RET_STRUCT)
        ArgKind[] retStructFieldKinds;
        uint retStructSize;  // total size in bytes
    }

    private {
        // Output buffer
        Appender!(ubyte[]) output;

        // Type index mapping
        uint[FuncSig] typeIndex;

        // Built-in functions
        bool hasBuiltins = false;
        uint allocFuncIndex;

        // FFI metadata (for extern(C) imports and ObjC sends)
        FFIMeta[] ffiMetas;

    }

    // ObjC interface lookup (package-visible for codegen)
    package InterfaceDecl[string] objcInterfaces;

    // ObjC class lookup (package-visible for codegen — classes with method bodies)
    package ClassDecl[string] objcClasses;

    /// Metadata for one ObjC class method (for objc_classes section)
    private struct ObjCMethodMeta {
        string selector;
        string wasmExport;   // e.g. "__objc_impl_MetalView_mouseDown"
        string typeEncoding;
        ArgKind retKind;
        ArgKind[] paramKinds;  // excluding self/_cmd
    }

    /// Metadata for one ObjC class (for objc_classes section)
    private struct ObjCClassMeta {
        string className;
        string superName;
        ObjCMethodMeta[] methods;
    }

    private {
        ObjCClassMeta[] objcClassMetas;
        bool objcHelpersAdded = false;
        uint[string] cStringOffsets;  // cached data section offsets for C strings

        // State
        EmitPhase phase = EmitPhase.init;
        string lastError;
        SourceLocation lastErrorLocation;
        
        // Memory tracking
        bool needsMemory = false;
        uint memoryPages = 2;  // Page 0: data+stack, Page 1+: arena (growable)
        
        // Globals (heap_ptr, etc.)
        struct GlobalInfo {
            ValType type;
            bool mutable;
            long initValue;
            double initF64 = 0.0;
            string name;
        }
        GlobalInfo[] globals;
        uint heapPtrGlobal;  // Index of $heap_ptr global
        bool needsShadowStack = false;  // Set when any function has struct locals

        // Function table for call_indirect (virtual dispatch + delegates)
        uint[] tableFunctions;        // function indices to put in table
        uint nextTypeId = 0;          // next available type ID for classes
        ClassDecl[] classesWithVtables;  // classes that need vtable entries

        // Lambda/delegate support
        uint[string] lambdaTableIndex;  // mangledName → table slot index
        
        // TypeInfo table: typeId -> offset in data section
        uint[] typeInfoOffsets;
        
        // Data section
        struct DataEntry {
            uint offset;
            ubyte[] data;
        }
        DataEntry[] dataEntries;
        uint nextDataOffset;  // Set after reserved area
        
        // Array literals: maps string content to struct address
        struct ArrayLiteralInfo {
            uint structOffset;   // Where the Array struct is in memory
            uint dataOffset;     // Where the character data is
            uint length;
        }
        ArrayLiteralInfo[string] arrayLiterals;
        uint[string] manifestArrayAddrs;  // Manifest constant arrays (import(), etc.)
        
        // Code caching for incremental compilation
        string sourceText;  // Full source text (for extracting function bodies)
        ubyte[][string] codeCache;  // function name -> cached code bytes
        SourceHash[string] sourceHashes;  // function name -> source hash
        bool[string] cacheHits;  // Track which functions used cache
        
        // Call stack frame info (milestone 144)
        // Maps function name to its frame info in the data section
        struct CallStackFrameInfo {
            uint nameOffset;   // Offset of function name in data section
            uint nameLen;      // Length of function name
            uint fileOffset;   // Offset of file name in data section
            uint fileLen;      // Length of file name
            uint line;         // Line number of function definition
            uint column;       // Column number
        }
        CallStackFrameInfo[string] callStackFrameInfos;
        uint callStackStringPoolOffset;  // Next offset in string pool area
    }
    
    this(SymbolTable symbolTable, bool enableStackTrace = true) {
        import codegen.wasm.types : CALL_STACK_STRING_POOL_OFFSET;
        this.symbolTable = symbolTable;
        this.enableStackTrace = enableStackTrace;
        this.nextDataOffset = MEMORY_RESERVED;  // Start after reserved area
        this.callStackStringPoolOffset = CALL_STACK_STRING_POOL_OFFSET;
    }
    
    //==========================================================================
    // Code Caching Interface
    //==========================================================================
    
    /**
     * Set the source text for extracting function bodies.
     * Call this before emit() to enable source hashing.
     */
    void setSourceText(string source) {
        this.sourceText = source;
    }
    
    /**
     * Pre-populate the code cache with previously compiled function code.
     * The cache maps function name to (source_hash, code_bytes).
     */
    void setCodeCache(CacheEntry[] entries) {
        foreach (entry; entries) {
            codeCache[entry.memberName] = entry.wasmBytes.dup;
            sourceHashes[entry.memberName] = entry.sourceHash;
        }
    }
    
    /**
     * Get the emitted code for a function (for caching).
     * Returns null if function not found.
     */
    CacheEntry[] getEmittedCode() {
        CacheEntry[] results;
        foreach (f; functions) {
            if (f.name in codeCache) {
                CacheEntry entry;
                entry.memberName = f.name;
                entry.sourceHash = sourceHashes.get(f.name, SourceHash.init);
                entry.wasmBytes = codeCache[f.name].dup;
                results ~= entry;
            }
        }
        return results;
    }
    
    /**
     * Get cache statistics.
     */
    struct CacheStats {
        size_t totalFunctions;
        size_t cacheHits;
        size_t cacheMisses;
    }
    
    CacheStats getCacheStats() {
        CacheStats stats;
        // Exclude builtins (f.decl is null) — they're deterministic, not cached
        size_t builtinCount = 0;
        foreach (f; functions)
            if (f.decl is null) builtinCount++;
        stats.totalFunctions = functions.length - builtinCount;
        stats.cacheHits = cacheHits.length;
        stats.cacheMisses = stats.totalFunctions - stats.cacheHits;
        return stats;
    }
    
    /**
     * Evict entries from the code cache by mangled name.
     * Used by dep-graph invalidation to remove transitively dirty functions.
     */
    void evictFromCache(const(string[]) dirtyNames) {
        foreach (name; dirtyNames) {
            codeCache.remove(name);
            sourceHashes.remove(name);
        }
    }

    /**
     * Compute source hash for a function by extracting its source text.
     */
    private SourceHash computeFunctionHash(FuncInfo f) {
        if (sourceText.length == 0 || f.decl is null) {
            return SourceHash.init;
        }
        
        auto loc = f.decl.location;
        if (loc.endOffset <= loc.startOffset || loc.endOffset > sourceText.length) {
            return SourceHash.init;
        }
        
        string funcSource = sourceText[loc.startOffset .. loc.endOffset];
        return computeSourceHash(funcSource);
    }
    
    /**
     * Compute hash from source text using MurmurHash3.
     */
    private static SourceHash computeSourceHash(string source) {
        SourceHash result;
        auto hash1 = MurmurHash3!128(0);
        auto hash2 = MurmurHash3!128(0x9E3779B9);
        
        hash1.put(cast(const(ubyte)[])source);
        hash2.put(cast(const(ubyte)[])source);
        
        auto h1 = hash1.finish();
        auto h2 = hash2.finish();
        
        result[0..16] = h1[];
        result[16..32] = h2[];
        return result;
    }
    
    //==========================================================================
    // Main Entry Point
    //==========================================================================
    
    /**
     * Emit binary WASM from declarations
     * Returns null on error (check lastError)
     */
    ubyte[] emit(ModulesContext ctx) {
        try {
            phase = EmitPhase.collecting;
            collectFromModules(ctx);

            return emitAfterCollect();
        } catch (EmitError e) {
            phase = EmitPhase.error;
            lastError = e.msg;
            lastErrorLocation = e.location;
            return null;
        } catch (Exception e) {
            phase = EmitPhase.error;
            lastError = "Internal error: " ~ e.msg;
            return null;
        }
    }

    ubyte[] emit(Declaration[] decls) {
        try {
            phase = EmitPhase.collecting;
            collect(decls);

            return emitAfterCollect();
        } catch (EmitError e) {
            phase = EmitPhase.error;
            lastError = e.msg;
            lastErrorLocation = e.location;
            return null;
        } catch (Exception e) {
            phase = EmitPhase.error;
            lastError = "Internal error: " ~ e.msg;
            return null;
        }
    }

    /// Shared post-collection emission pipeline (used by both emit overloads).
    private ubyte[] emitAfterCollect() {
        // Pre-allocate exception slot array in data section (must be before finalizeHeapPtr)
        allocateExceptionSlotArray();

        // If array/heap operations are needed, add built-ins
        if (needsArraySupport) {
            addArrayBuiltins();
            addArenaBuiltins();
            finalizeHeapPtr();
            finalizeArenaBase();
        }

        // Always add shadow stack for struct locals
        addShadowStackGlobal();

        // Exception handling globals (always allocated — needed for scope guards too)
        addExceptionGlobals();

        // Add call stack tracking global if enabled
        if (enableStackTrace) {
            addCallStackGlobal();
        }

        // Add imports for CTFE-only functions that are called
        addCTFEImports();

        // Stabilize indices for incremental compilation
        stabilizeIndices();

        // Build function table for virtual dispatch (must be after stabilization)
        buildVtables();

        // Collect lifted lambda functions and add them to the function table
        collectLiftedLambdas();

        phase = EmitPhase.init;
        emitHeader();

        phase = EmitPhase.emittingTypes;
        emitTypeSection();

        // Import section must come before function section
        emitImportSection();

        phase = EmitPhase.emittingFunctions;
        emitFunctionSection();

        // Table section (for call_indirect / virtual dispatch)
        emitTableSection();

        phase = EmitPhase.emittingMemory;
        emitMemorySection();

        // Emit globals section (for heap_ptr)
        emitGlobalSection();

        phase = EmitPhase.emittingExports;
        emitExportSection();

        // Element section (populates function table) - must come after export
        emitElementSection();

        phase = EmitPhase.emittingCode;
        emitCodeSection();

        phase = EmitPhase.emittingData;
        emitDataSection();

        // Custom FFI metadata section (only when extern(C) imports exist)
        if (ffiMetas.length > 0) {
            emitFFIMetaSection();
        }

        // Custom ObjC classes section (only when extern(Objective-C) classes exist)
        if (objcClassMetas.length > 0) {
            emitObjCClassesSection();
        }

        phase = EmitPhase.done;
        return output.data.dup;
    }
    
    /**
     * Get last error message
     */
    string error() const {
        return lastError;
    }

    /**
     * Get the source location of the last error, if available
     */
    SourceLocation errorLocation() const {
        return lastErrorLocation;
    }
    
    //==========================================================================
    // Expression Evaluator (for CTFE)
    //==========================================================================
    
    /**
     * Emit a module that evaluates a string expression and returns the result pointer.
     * Used by CTFE to evaluate string operations via the same codegen as final output.
     * 
     * The module exports:
     * - __eval(): i32  - evaluates expression, returns pointer to Array struct
     * - memory         - for reading the result
     * - __heap_ptr     - for debugging
     */
    ubyte[] emitArrayExpressionModule(Expression expr) {
        try {
            // Reset state for a fresh module
            output.clear();
            types.length = 0;
            typeIndex.clear();
            functions.length = 0;
            funcIndex.clear();
            globals.length = 0;
            dataEntries.length = 0;
            arrayLiterals.clear();
            manifestArrayAddrs.clear();
            nextDataOffset = MEMORY_RESERVED;
            needsArraySupport = true;  // We're evaluating strings
            hasBuiltins = false;
            hasArenaBuiltins = false;

            // Collect array literals from the expression
            collectArrayLiterals(expr);

            // Pre-allocate exception slot array (must be before finalizeHeapPtr)
            allocateExceptionSlotArray();

            // Add built-ins (__alloc, __array_concat, arena)
            addArrayBuiltins();
            addArenaBuiltins();

            // Add the __eval function
            addEvalFunction(expr);

            // Finalize heap pointer and arena
            finalizeHeapPtr();
            finalizeArenaBase();
            
            // Emit the module
            emitHeader();
            emitTypeSection();
            emitFunctionSection();
            emitMemorySection();
            emitGlobalSection();
            emitExportSection();
            emitCodeSection();
            emitDataSection();
            
            return output.data.dup;
            
        } catch (EmitError e) {
            lastError = e.msg;
            lastErrorLocation = e.location;
            return null;
        } catch (Exception e) {
            lastError = "Internal error: " ~ e.msg;
            return null;
        }
    }

    /**
     * Emit a minimal module that evaluates an integer expression.
     * Used by CTFE to evaluate arithmetic/comparison expressions via the backend.
     *
     * The module exports:
     * - __eval(): i32  - evaluates expression, returns the integer result
     */
    ubyte[] emitIntExpressionModule(Expression expr) {
        try {
            // Reset state for a fresh module
            output.clear();
            types.length = 0;
            typeIndex.clear();
            functions.length = 0;
            funcIndex.clear();
            globals.length = 0;
            dataEntries.length = 0;
            arrayLiterals.clear();
            manifestArrayAddrs.clear();
            nextDataOffset = MEMORY_RESERVED;
            needsArraySupport = false;
            hasBuiltins = false;
            hasArenaBuiltins = false;

            // Add the __eval function
            addEvalFunction(expr);

            // Emit the module (minimal — no memory, no data)
            emitHeader();
            emitTypeSection();
            emitFunctionSection();
            emitExportSection();
            emitCodeSection();

            return output.data.dup;

        } catch (EmitError e) {
            lastError = e.msg;
            lastErrorLocation = e.location;
            return null;
        } catch (Exception e) {
            lastError = "Internal error: " ~ e.msg;
            return null;
        }
    }

    /**
     * Emit a minimal module that evaluates a float expression.
     * Used by CTFE to evaluate float arithmetic expressions via the backend.
     *
     * The module exports:
     * - __eval(): f64  - evaluates expression, returns the float result
     */
    ubyte[] emitFloatExpressionModule(Expression expr) {
        try {
            // Reset state for a fresh module
            output.clear();
            types.length = 0;
            typeIndex.clear();
            functions.length = 0;
            funcIndex.clear();
            globals.length = 0;
            dataEntries.length = 0;
            arrayLiterals.clear();
            manifestArrayAddrs.clear();
            nextDataOffset = MEMORY_RESERVED;
            needsArraySupport = false;
            hasBuiltins = false;
            hasArenaBuiltins = false;

            // Add the __eval function with f64 return type
            addEvalFunction(expr, ValType.f64);

            // Emit the module (minimal — no memory, no data)
            emitHeader();
            emitTypeSection();
            emitFunctionSection();
            emitExportSection();
            emitCodeSection();

            return output.data.dup;

        } catch (EmitError e) {
            lastError = e.msg;
            lastErrorLocation = e.location;
            return null;
        } catch (Exception e) {
            lastError = "Internal error: " ~ e.msg;
            return null;
        }
    }

    /**
     * Recursively collect array literals from an expression.
     */
    private void collectArrayLiterals(Expression expr) {
        if (auto literal = cast(LiteralExpression)expr) {
            if (literal.value.type == typeid(string)) {
                registerArrayLiteral(literal.value.get!string());
            }
        } else if (auto binary = cast(BinaryExpression)expr) {
            collectArrayLiterals(binary.left);
            collectArrayLiterals(binary.right);
        } else if (auto ident = cast(IdentifierExpression)expr) {
            // If it's a manifest constant string, register it
            auto symbol = symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.isConstant) {
                if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                    if (manifest.ctfeComplete && manifest.isStringType) {
                        registerArrayLiteral(manifest.ctfeStringValue);
                    }
                }
            }
        } else if (auto call = cast(CallExpression)expr) {
            // Handle __text intrinsic - evaluate and pre-register the result string
            auto ident = cast(IdentifierExpression)call.function_;
            if (ident && ident.name == "__text" && call.arguments.length == 1) {
                long value = evaluateConstantIntExpr(call.arguments[0]);
                string strValue = to!string(value);
                registerArrayLiteral(strValue);
            }
        }
    }
    
    /**
     * Evaluate an integer expression from manifest constants (for collectArrayLiterals).
     */
    private long evaluateConstantIntExpr(Expression expr) {
        if (auto literal = cast(LiteralExpression)expr) {
            if (literal.value.type == typeid(long)) {
                return literal.value.get!long();
            }
        }
        
        if (auto ident = cast(IdentifierExpression)expr) {
            auto symbol = symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.isConstant) {
                if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                    if (!manifest.isStringType) {
                        manifest.ensureEvaluated();
                        return manifest.ctfeValue;
                    }
                }
            }
        }

        if (auto binary = cast(BinaryExpression)expr) {
            long left = evaluateConstantIntExpr(binary.left);
            long right = evaluateConstantIntExpr(binary.right);
            
            final switch (binary.operator) {
                case BinaryExpression.Operator.Add: return left + right;
                case BinaryExpression.Operator.Subtract: return left - right;
                case BinaryExpression.Operator.Multiply: return left * right;
                case BinaryExpression.Operator.Divide: return left / right;
                case BinaryExpression.Operator.Modulo: return left % right;
                case BinaryExpression.Operator.Equal: return left == right ? 1 : 0;
                case BinaryExpression.Operator.NotEqual: return left != right ? 1 : 0;
                case BinaryExpression.Operator.Less: return left < right ? 1 : 0;
                case BinaryExpression.Operator.LessEqual: return left <= right ? 1 : 0;
                case BinaryExpression.Operator.Greater: return left > right ? 1 : 0;
                case BinaryExpression.Operator.GreaterEqual: return left >= right ? 1 : 0;
                case BinaryExpression.Operator.LogicalAnd: return (left != 0 && right != 0) ? 1 : 0;
                case BinaryExpression.Operator.LogicalOr: return (left != 0 || right != 0) ? 1 : 0;
                case BinaryExpression.Operator.BitwiseAnd: return left & right;
                case BinaryExpression.Operator.BitwiseOr: return left | right;
                case BinaryExpression.Operator.BitwiseXor: return left ^ right;
                case BinaryExpression.Operator.ShiftLeft: return left << right;
                case BinaryExpression.Operator.ShiftRight: return left >> right;
                case BinaryExpression.Operator.UnsignedShiftRight: return left >>> right;
                case BinaryExpression.Operator.Concat: return 0;  // Not applicable
            }
        }
        
        return 0;  // Default for unknown expressions
    }
    
    /**
     * Add the __eval function that evaluates the expression.
     */
    private void addEvalFunction(Expression expr, ValType returnType = ValType.i32) {
        FuncSig evalSig;
        evalSig.params = [];
        evalSig.results = [returnType];
        
        uint evalTypeIdx;
        if (auto existing = evalSig in typeIndex) {
            evalTypeIdx = *existing;
        } else {
            evalTypeIdx = cast(uint)types.length;
            types ~= evalSig;
            typeIndex[evalSig] = evalTypeIdx;
        }
        
        // Create a dummy FuncInfo for __eval
        FuncInfo evalFunc;
        evalFunc.name = "__eval";
        evalFunc.typeIndex = evalTypeIdx;
        evalFunc.decl = null;  // Built-in
        evalFunc.exported = true;
        funcIndex["__eval"] = cast(uint)functions.length;
        functions ~= evalFunc;
        
        // Store the expression for emitBuiltinBody to use
        evalExpression = expr;
    }
    
    // Expression to evaluate (for __eval function)
    private Expression evalExpression;
    
    //==========================================================================
    // Phase 0: Collection
    //==========================================================================
    
    private void collect(Declaration[] decls) {
        // Pass 0a: Register all ObjC interfaces and classes in map (names only)
        foreach (decl; decls) {
            if (auto ifaceDecl = cast(InterfaceDecl)decl) {
                if (ifaceDecl.isObjC) objcInterfaces[ifaceDecl.name] = ifaceDecl;
            }
            if (auto classDecl = cast(ClassDecl)decl) {
                if (classDecl.isObjC) objcClasses[classDecl.name] = classDecl;
            }
        }
        // Pass 0b: Process ObjC interface methods (can now resolve cross-refs)
        foreach (decl; decls) {
            if (auto ifaceDecl = cast(InterfaceDecl)decl) {
                if (ifaceDecl.isObjC) collectObjCInterface(ifaceDecl);
            }
        }
        // Pass 0c: Process ObjC class methods (compile as exported functions)
        foreach (decl; decls) {
            if (auto classDecl = cast(ClassDecl)decl) {
                if (classDecl.isObjC) collectObjCClass(classDecl);
            }
        }
        // Pass 1: Imported functions (can reference ObjC interface types)
        foreach (decl; decls) {
            if (auto importedFunc = cast(ImportedFunctionDecl)decl) {
                collectImportedFunction(importedFunc);
            }
        }

        // Second pass: collect local functions, global variables, and struct methods
        foreach (decl; decls) {
            // Track module boundaries so each function is mangled with the correct module path
            if (auto modDecl = cast(ModuleDecl)decl) {
                symbolTable.setModulePath(modDecl.modulePath);
                continue;
            }
            if (cast(ImportDecl)decl || cast(PragmaDeclaration)decl) {
                continue;  // Import/pragma declarations handled elsewhere
            }
            if (cast(TemplateDecl)decl) {
                continue;  // Skip uninstantiated templates
            } else if (auto funcDecl = cast(FunctionDecl)decl) {
                collectFunction(funcDecl);
            } else if (auto varDecl = cast(VariableDecl)decl) {
                collectGlobalVariable(varDecl);
            } else if (auto structDecl = cast(StructDecl)decl) {
                // Collect methods from struct declarations
                collectStructMethods(structDecl);
            } else if (auto classDecl = cast(ClassDecl)decl) {
                if (!classDecl.isObjC) {
                    // Collect methods and generate vtable for class (non-ObjC only)
                    collectClassMethods(classDecl);
                }
            }
        }
    }

    /// Collect declarations from ModulesContext — each module processed once, no duplicates.
    private void collectFromModules(ModulesContext ctx) {
        // Pass 0a: Register all ObjC interfaces and classes in map (names only) across all modules
        foreach (mod; ctx.modulesInOrder()) {
            foreach (decl; mod.ast) {
                if (auto ifaceDecl = cast(InterfaceDecl)decl) {
                    if (ifaceDecl.isObjC) objcInterfaces[ifaceDecl.name] = ifaceDecl;
                }
                if (auto classDecl = cast(ClassDecl)decl) {
                    if (classDecl.isObjC) objcClasses[classDecl.name] = classDecl;
                }
            }
        }
        // Pass 0b: Process ObjC interface methods (can now resolve cross-refs)
        foreach (mod; ctx.modulesInOrder()) {
            foreach (decl; mod.ast) {
                if (auto ifaceDecl = cast(InterfaceDecl)decl) {
                    if (ifaceDecl.isObjC) collectObjCInterface(ifaceDecl);
                }
            }
        }
        // Pass 0c: Process ObjC class methods (compile as exported functions)
        foreach (mod; ctx.modulesInOrder()) {
            foreach (decl; mod.ast) {
                if (auto classDecl = cast(ClassDecl)decl) {
                    if (classDecl.isObjC) collectObjCClass(classDecl);
                }
            }
        }
        // Pass 1: Imported functions (can reference ObjC interface types)
        foreach (mod; ctx.modulesInOrder()) {
            foreach (decl; mod.ast) {
                if (auto importedFunc = cast(ImportedFunctionDecl)decl) {
                    collectImportedFunction(importedFunc);
                }
            }
        }

        // Second pass: collect local functions, globals, struct/class methods per module
        foreach (mod; ctx.modulesInOrder()) {
            symbolTable.setModulePath(mod.modulePath);
            foreach (decl; mod.ast) {
                if (cast(ModuleDecl)decl)
                    continue;
                if (cast(ImportDecl)decl || cast(PragmaDeclaration)decl)
                    continue;
                if (cast(TemplateDecl)decl) {
                    continue;
                } else if (auto funcDecl = cast(FunctionDecl)decl) {
                    collectFunction(funcDecl);
                } else if (auto varDecl = cast(VariableDecl)decl) {
                    collectGlobalVariable(varDecl);
                } else if (auto structDecl = cast(StructDecl)decl) {
                    collectStructMethods(structDecl);
                } else if (auto classDecl = cast(ClassDecl)decl) {
                    if (!classDecl.isObjC) {
                        collectClassMethods(classDecl);
                    }
                }
            }
        }
    }

    /**
     * Collect methods from a struct declaration.
     * Methods are registered with mangled names: StructName_methodName
     */
    private void collectStructMethods(StructDecl structDecl) {
        // If struct has slice fields, methods may need array support (append, etc.)
        foreach (field; structDecl.fields) {
            if (auto at = cast(ArrayType) field.type) {
                if (!at.isStaticArray) {
                    needsArraySupport = true;
                    break;
                }
            }
        }
        foreach (member; structDecl.members) {
            if (auto funcDecl = cast(FunctionDecl)member) {
                if (funcDecl.isMethod) {
                    collectMethod(structDecl, funcDecl);
                }
            }
        }
    }
    
    /**
     * Build a ParamLayout for a function declaration with the given context.
     */
    private ParamLayout buildLayout(FunctionDecl decl, bool isMethod, bool isExportedMain) {
        // Ensure all parameter types are resolved before layout computation
        // (UserType.asInterface() etc. need declaration set)
        foreach (p; decl.parameters) {
            if (auto ut = cast(UserType)p.type)
                ut.ensureResolved(symbolTable);
        }
        return computeParamLayout(decl, ParamLayoutContext(
            isMethod,
            isLargeReturnType(decl.returnType),
            decl.needsArena,
            isExportedMain,
            &dTypeToValType,
            isVoidType(decl.returnType),
            isVoidType(decl.returnType) ? ValType.i32 : dTypeToValType(decl.returnType),
        ));
    }

    /**
     * Register a function from its ParamLayout: build FuncSig, get type index.
     */
    private uint registerSignature(ref ParamLayout layout) {
        FuncSig sig;
        sig.params = layout.wasmParams;
        sig.results = layout.wasmResults;

        if (auto existing = sig in typeIndex) {
            return *existing;
        }
        auto tIdx = cast(uint)types.length;
        types ~= sig;
        typeIndex[sig] = tIdx;
        return tIdx;
    }

    /**
     * Collect a struct method, adding hidden 'this' parameter.
     */
    private void collectMethod(StructDecl structDecl, FunctionDecl method) {
        // Scan method body for local slice types and CTFE calls
        scanForSliceTypes(method);

        auto layout = buildLayout(method, true, false);
        uint tIdx = registerSignature(layout);

        // Generate D ABI mangled name
        import codegen.mangle : computeMangledName;
        method.mangledName = computeMangledName(symbolTable.modulePath, method);

        // Create function info
        FuncInfo info;
        info.name = method.mangledName;
        info.decl = method;
        info.typeIndex = tIdx;
        info.isImport = false;
        info.structParent = structDecl;
        info.paramLayout = layout;

        funcIndex[method.mangledName] = cast(uint)functions.length;
        functions ~= info;
    }

    /**
     * Collect methods from a class declaration and set up virtual dispatch.
     * 
     * Packed vtable_ptr design (see codegen.target.VtablePacking):
     *   vtable_ptr = (typeId << TYPE_ID_SHIFT) | tableBase
     *   
     *   - typeId:    unique ID for this class (for RTTI/error messages)
     *   - tableBase: starting index in WASM function table
     *   
     * Virtual call:
     *   tableIndex = (vtable_ptr & TABLE_BASE_MASK) + methodSlot
     *   call_indirect tableIndex
     * 
     * TypeInfo (in data section, indexed by typeId):
     *   [nameOffset: u32, nameLen: u32]
     */
    private void collectClassMethods(ClassDecl classDecl) {
        import std.algorithm : filter, countUntil;
        
        // Assign unique type ID
        classDecl.typeId = nextTypeId++;
        
        // Assign tableBase = current end of function table
        classDecl.tableBase = cast(uint)tableFunctions.length;
        
        // Build virtualMethods array
        // For inheritance: start with base class methods, then override/extend
        if (classDecl.baseClassDecl) {
            // Ensure base class is processed first
            if (classDecl.baseClassDecl.virtualMethods.length == 0 && 
                !classesWithVtables.canFind(classDecl.baseClassDecl)) {
                collectClassMethods(classDecl.baseClassDecl);
            }
            
            // Inherit base class virtual methods (will be replaced by overrides)
            classDecl.virtualMethods = classDecl.baseClassDecl.virtualMethods.dup;
        } else {
            classDecl.virtualMethods = [];
        }
        
        // Process this class's methods
        foreach (member; classDecl.members) {
            if (auto funcDecl = cast(FunctionDecl)member) {
                if (funcDecl.isMethod) {
                    // Register the method (creates function entry)
                    collectClassMethod(classDecl, funcDecl);
                    
                    // Handle virtual methods (non-constructor, non-destructor)
                    if (!funcDecl.isConstructor && !funcDecl.isDestructor) {
                        // Check if this overrides a base class method
                        auto overrideIdx = classDecl.virtualMethods.countUntil!(
                            m => m.name == funcDecl.name
                        );
                        
                        if (overrideIdx >= 0) {
                            // Override: replace the inherited slot
                            classDecl.virtualMethods[overrideIdx] = funcDecl;
                        } else {
                            // New method: append to vtable
                            classDecl.virtualMethods ~= funcDecl;
                        }
                    }
                }
            }
        }
        
        // Track this class for post-stabilization table building
        classesWithVtables ~= classDecl;
        
        // Generate TypeInfo in data section
        generateTypeInfo(classDecl);
    }
    
    /**
     * Collect a class method, adding hidden 'this' parameter.
     */
    private void collectClassMethod(ClassDecl classDecl, FunctionDecl method) {
        auto layout = buildLayout(method, true, false);
        uint tIdx = registerSignature(layout);

        // Generate D ABI mangled name
        import codegen.mangle : computeMangledName;
        method.mangledName = computeMangledName(symbolTable.modulePath, method);

        FuncInfo info;
        info.name = method.mangledName;
        info.decl = method;
        info.typeIndex = tIdx;
        info.isImport = false;
        info.classParent = classDecl;
        info.paramLayout = layout;

        funcIndex[method.mangledName] = cast(uint)functions.length;
        functions ~= info;
    }
    
    /**
     * Generate TypeInfo for a class in the data section.
     * TypeInfo is indexed by typeId for error messages.
     */
    private void generateTypeInfo(ClassDecl classDecl) {
        // Emit class name string
        uint nameOffset = addData(cast(ubyte[])classDecl.name.dup);
        uint nameLen = cast(uint)classDecl.name.length;
        
        // Emit TypeInfo struct: {nameOffset, nameLen}
        ubyte[8] typeInfo;
        *cast(uint*)&typeInfo[0] = nameOffset;
        *cast(uint*)&typeInfo[4] = nameLen;
        classDecl.typeInfoOffset = addData(typeInfo[]);
        
        // Track TypeInfo offset by typeId
        while (typeInfoOffsets.length <= classDecl.typeId) {
            typeInfoOffsets ~= 0;
        }
        typeInfoOffsets[classDecl.typeId] = classDecl.typeInfoOffset;
    }
    
    /**
     * Collect a global variable, evaluating struct initializers to data section
     */
    private void collectGlobalVariable(VariableDecl decl) {
        // Check if it's a struct type with an initializer
        if (auto ut = cast(UserType)decl.type)
            ut.ensureResolved(symbolTable);
        if (auto structDecl = decl.type.asStruct()) {
            if (decl.initializer) {
                // Try to evaluate the initializer as a struct literal
                if (auto callExpr = cast(CallExpression)decl.initializer) {
                    // Point(42, 10) looks like a call
                    int[] fieldValues;
                    foreach (arg; callExpr.arguments) {
                        if (auto lit = cast(LiteralExpression)arg) {
                            if (lit.value.type == typeid(long)) {
                                fieldValues ~= cast(int)lit.value.get!long();
                            } else if (lit.value.type == typeid(bool)) {
                                fieldValues ~= lit.value.get!bool() ? 1 : 0;
                            }
                        } else {
                            // Complex expression - try CTFE evaluation
                            fieldValues ~= cast(int)evaluateConstantIntExpr(arg);
                        }
                    }

                    if (fieldValues.length == structDecl.fields.length) {
                        decl.ctfeStructAddress = registerStructLiteral(structDecl, fieldValues);
                        decl.ctfeComplete = true;
                    }
                }
            }
            return;
        }

        // Scalar global variable — allocate a WASM global
        decl.wasmGlobalIndex = cast(uint)globals.length;
        GlobalInfo g;
        g.type = dTypeToValType(decl.type);
        g.mutable = true;
        g.name = decl.name;

        if (g.type == ValType.f64 || g.type == ValType.f32) {
            // Float/double global — evaluate initializer as f64
            if (decl.initializer) {
                if (auto literal = cast(LiteralExpression)decl.initializer) {
                    if (literal.value.type == typeid(double))
                        g.initF64 = literal.value.get!double();
                    else if (literal.value.type == typeid(long))
                        g.initF64 = cast(double)literal.value.get!long();
                }
            }
        } else {
            // Integer global
            if (decl.initializer) {
                g.initValue = evaluateConstantIntExpr(decl.initializer);
            }
        }

        globals ~= g;
    }
    
    private void collectImportedFunction(ImportedFunctionDecl decl) {
        // Resolve ObjC interface types in return type and parameters
        resolveObjCUserType(cast(UserType)decl.returnType);
        foreach (p; decl.parameters) {
            resolveObjCUserType(cast(UserType)p.type);
        }

        // Build signature
        FuncSig sig;
        sig.params = decl.parameters.map!(p => dTypeToValType(p.type)).array;

        if (!isVoidType(decl.returnType)) {
            sig.results = [dTypeToValType(decl.returnType)];
        }

        // Get or create type index
        uint tIdx;
        if (auto existing = sig in typeIndex) {
            tIdx = *existing;
        } else {
            tIdx = cast(uint)types.length;
            types ~= sig;
            typeIndex[sig] = tIdx;
        }

        // Add import
        ImportInfo info;
        info.moduleName = decl.moduleName;
        info.fieldName = decl.name;
        info.typeIndex = tIdx;

        // Imported functions occupy the first N function indices
        importIndex[decl.name] = cast(uint)imports.length;
        imports ~= info;

        // Track FFI metadata for extern(C) imports
        if (decl.moduleName == "ffi") {
            FFIMeta meta;
            meta.name = decl.name;
            meta.retKind = isVoidType(decl.returnType) ? ArgKind.RET_VOID : dTypeToArgKind(decl.returnType);
            meta.paramKinds = decl.parameters.map!(p => dTypeToArgKind(p.type)).array;
            ffiMetas ~= meta;
        }
    }

    /// Collect an extern(Objective-C) interface: generate FFI imports for each method
    private void collectObjCInterface(InterfaceDecl ifaceDecl) {
        ensureObjCHelpers();

        foreach (method; ifaceDecl.methods) {
            // Resolve ObjC interface types in return type and parameters
            resolveObjCUserType(cast(UserType)method.returnType);
            foreach (p; method.parameters) {
                resolveObjCUserType(cast(UserType)p.type);
            }
            string selector = method.objcSelector;
            if (selector is null) selector = method.name;

            // Detect struct return type
            auto resolvedRet = method.returnType.resolve();
            if (auto ut = cast(UserType)resolvedRet) {
                if (!ut.declaration) ut.ensureResolved(symbolTable);
            }
            auto retStructDecl = resolvedRet.asStruct();
            bool isStructReturn = retStructDecl !is null;

            // WASM signature: [i64 receiver, i64 selector, (i32 result_ptr if struct return), ...user_params]
            FuncSig sig;
            sig.params ~= ValType.i64;  // receiver (opaque native pointer)
            sig.params ~= ValType.i64;  // selector (opaque native pointer)
            if (isStructReturn) {
                sig.params ~= ValType.i32;  // hidden result pointer
            }
            foreach (p; method.parameters) {
                auto resolved = p.type.resolve();
                // Resolve struct UserTypes for field access
                if (auto ut = cast(UserType)resolved) {
                    if (!ut.declaration) ut.ensureResolved(symbolTable);
                }
                if (auto structDecl = resolved.asStruct()) {
                    // Flatten HFA: push one ValType per field
                    assert(structDecl.layoutComputed, "ObjC struct param " ~ p.name ~ ": layout not computed");
                    assert(structDecl.fields.length > 0, "ObjC struct param " ~ p.name ~ ": no fields");
                    foreach (field; structDecl.fields)
                        sig.params ~= dTypeToValType(field.type);
                } else {
                    sig.params ~= dTypeToValType(p.type);
                }
            }

            if (isStructReturn) {
                // No WASM return — caller uses the result pointer on shadow stack
            } else {
                bool isVoid = isVoidType(method.returnType);
                if (!isVoid) {
                    sig.results = [dTypeToValType(method.returnType)];
                }
            }

            // Unique import name per method
            string importName = "__objc_send_" ~ ifaceDecl.name ~ "_" ~ method.name;

            // Get or create type index
            uint tIdx;
            if (auto existing = sig in typeIndex) {
                tIdx = *existing;
            } else {
                tIdx = cast(uint)types.length;
                types ~= sig;
                typeIndex[sig] = tIdx;
            }

            // Register as FFI import
            ImportInfo info;
            info.moduleName = "ffi";
            info.fieldName = importName;
            info.typeIndex = tIdx;
            importIndex[importName] = cast(uint)imports.length;
            imports ~= info;

            // FFI meta with native name alias -> objc_msgSend
            FFIMeta meta;
            meta.name = importName;
            meta.nativeName = "objc_msgSend";
            if (isStructReturn) {
                meta.retKind = ArgKind.RET_STRUCT;
                meta.paramKinds = [ArgKind.ARG_I64, ArgKind.ARG_I64, ArgKind.ARG_PTR];
                assert(retStructDecl.layoutComputed,
                    "ObjC struct return " ~ retStructDecl.name ~ ": layout not computed");
                meta.retStructSize = cast(uint)retStructDecl.aggregateSize_;
                foreach (field; retStructDecl.fields)
                    meta.retStructFieldKinds ~= dTypeToArgKind(field.type);
            } else {
                bool isVoid = isVoidType(method.returnType);
                meta.retKind = isVoid ? ArgKind.RET_VOID : dTypeToArgKind(method.returnType);
                meta.paramKinds = [ArgKind.ARG_I64, ArgKind.ARG_I64];  // receiver + selector
            }
            foreach (p; method.parameters) {
                auto resolved = p.type.resolve();
                if (auto structDecl = resolved.asStruct()) {
                    // Flatten HFA: push one ArgKind per field
                    foreach (field; structDecl.fields)
                        meta.paramKinds ~= dTypeToArgKind(field.type);
                } else {
                    meta.paramKinds ~= dTypeToArgKind(p.type);
                }
            }
            assert(sig.params.length == meta.paramKinds.length,
                format("ObjC %s: WASM sig has %d params but FFI meta has %d paramKinds",
                       importName, sig.params.length, meta.paramKinds.length));
            ffiMetas ~= meta;

            // Store import name on the method for codegen lookup
            method.mangledName = importName;
        }
    }

    /**
     * Collect an extern(Objective-C) class — compile methods as exported WASM functions.
     * Each method gets signature (self:i64, _cmd:i64, ...user_params) → return_type,
     * exported as "__objc_impl_ClassName_methodName".
     * Also builds metadata for the objc_classes custom section.
     */
    private void collectObjCClass(ClassDecl classDecl) {
        ensureObjCHelpers();

        // Determine superclass name from the first interface (e.g., NSView, NSObject)
        string superName = "NSObject";  // default
        if (classDecl.interfaces.length > 0) {
            if (auto ut = cast(UserType)classDecl.interfaces[0]) {
                superName = ut.name;
            }
        }

        ObjCClassMeta classMeta;
        classMeta.className = classDecl.name;
        classMeta.superName = superName;

        // Also register this class's interface-like methods in objcInterfaces
        // so that callers using this class type can dispatch via emitObjCMethodCall.
        // We create a synthetic InterfaceDecl for the class.
        auto syntheticIface = new InterfaceDecl(classDecl.location, classDecl.name,
            cast(Type[])null, cast(FunctionDecl[])null);
        syntheticIface.isObjC = true;
        FunctionDecl[] ifaceMethods;

        foreach (member; classDecl.members) {
            auto method = cast(FunctionDecl)member;
            if (!method || !method.isMethod)
                continue;

            string selector = method.objcSelector;
            if (selector is null) selector = method.name;

            // Bodyless methods: register as ObjC send imports only (like interface methods)
            if (method.body_ is null) {
                collectObjCClassSendMethod(classDecl, method, selector, ifaceMethods);
                continue;
            }

            string exportName = "__objc_impl_" ~ classDecl.name ~ "_" ~ method.name;

            // Build WASM signature: (self:i64, _cmd:i64, ...user_params) → return_type
            FuncSig sig;
            sig.params ~= ValType.i64;  // self
            sig.params ~= ValType.i64;  // _cmd

            foreach (p; method.parameters) {
                auto resolved = p.type.resolve();
                if (auto ut = cast(UserType)resolved) {
                    if (!ut.declaration) ut.ensureResolved(symbolTable);
                }
                if (auto structDecl = resolved.asStruct()) {
                    assert(structDecl.layoutComputed, "ObjC class struct param " ~ p.name ~ ": layout not computed");
                    assert(structDecl.fields.length > 0, "ObjC class struct param " ~ p.name ~ ": no fields");
                    foreach (field; structDecl.fields)
                        sig.params ~= dTypeToValType(field.type);
                } else {
                    sig.params ~= dTypeToValType(p.type);
                }
            }

            bool isVoid = isVoidType(method.returnType);
            if (!isVoid) {
                sig.results = [dTypeToValType(method.returnType)];
            }

            uint tIdx;
            if (auto existing = sig in typeIndex) {
                tIdx = *existing;
            } else {
                tIdx = cast(uint)types.length;
                types ~= sig;
                typeIndex[sig] = tIdx;
            }

            // Register as a local function (not import) that gets exported
            method.mangledName = exportName;

            FuncInfo info;
            info.name = exportName;
            info.exportName = exportName;
            info.typeIndex = tIdx;
            info.decl = method;
            info.exported = true;
            info.classParent = classDecl;

            funcIndex[exportName] = cast(uint)functions.length;
            functions ~= info;

            // Build method metadata for objc_classes section
            ObjCMethodMeta methodMeta;
            methodMeta.selector = selector;
            methodMeta.wasmExport = exportName;
            methodMeta.typeEncoding = buildObjCTypeEncoding(method);
            methodMeta.retKind = isVoid ? ArgKind.RET_VOID : dTypeToArgKind(method.returnType);
            foreach (p; method.parameters) {
                auto resolved = p.type.resolve();
                if (auto structDecl = resolved.asStruct()) {
                    assert(structDecl.layoutComputed, "ObjC class struct param " ~ p.name ~ ": layout not computed");
                    foreach (field; structDecl.fields)
                        methodMeta.paramKinds ~= dTypeToArgKind(field.type);
                } else {
                    methodMeta.paramKinds ~= dTypeToArgKind(p.type);
                }
            }
            classMeta.methods ~= methodMeta;

            // Also register as ObjC send import (so other code can call this method
            // via objc_msgSend on instances of this class). Same pattern as interface.
            string sendImportName = "__objc_send_" ~ classDecl.name ~ "_" ~ method.name;

            // Detect struct return for send import
            auto resolvedRet = method.returnType.resolve();
            if (auto ut = cast(UserType)resolvedRet) {
                if (!ut.declaration) ut.ensureResolved(symbolTable);
            }
            auto retStructDecl = resolvedRet.asStruct();
            bool isStructReturn = retStructDecl !is null;

            // Build send import signature (may differ from impl if struct return)
            FuncSig sendSig;
            sendSig.params ~= ValType.i64;  // receiver
            sendSig.params ~= ValType.i64;  // selector
            if (isStructReturn) {
                sendSig.params ~= ValType.i32;  // hidden result pointer
            }
            foreach (p; method.parameters) {
                auto resolved = p.type.resolve();
                if (auto ut2 = cast(UserType)resolved) {
                    if (!ut2.declaration) ut2.ensureResolved(symbolTable);
                }
                if (auto sd = resolved.asStruct()) {
                    foreach (field; sd.fields)
                        sendSig.params ~= dTypeToValType(field.type);
                } else {
                    sendSig.params ~= dTypeToValType(p.type);
                }
            }
            if (!isStructReturn && !isVoid) {
                sendSig.results = [dTypeToValType(method.returnType)];
            }

            uint sendTIdx;
            if (auto existing = sendSig in typeIndex) {
                sendTIdx = *existing;
            } else {
                sendTIdx = cast(uint)types.length;
                types ~= sendSig;
                typeIndex[sendSig] = sendTIdx;
            }

            ImportInfo importInfo;
            importInfo.moduleName = "ffi";
            importInfo.fieldName = sendImportName;
            importInfo.typeIndex = sendTIdx;
            importIndex[sendImportName] = cast(uint)imports.length;
            imports ~= importInfo;

            FFIMeta meta;
            meta.name = sendImportName;
            meta.nativeName = "objc_msgSend";
            if (isStructReturn) {
                meta.retKind = ArgKind.RET_STRUCT;
                meta.paramKinds = [ArgKind.ARG_I64, ArgKind.ARG_I64, ArgKind.ARG_PTR];
                assert(retStructDecl.layoutComputed,
                    "ObjC struct return " ~ retStructDecl.name ~ ": layout not computed");
                meta.retStructSize = cast(uint)retStructDecl.aggregateSize_;
                foreach (field; retStructDecl.fields)
                    meta.retStructFieldKinds ~= dTypeToArgKind(field.type);
            } else {
                meta.retKind = isVoid ? ArgKind.RET_VOID : dTypeToArgKind(method.returnType);
                meta.paramKinds = [ArgKind.ARG_I64, ArgKind.ARG_I64];
            }
            foreach (p; method.parameters) {
                auto resolved = p.type.resolve();
                if (auto sd = resolved.asStruct()) {
                    foreach (field; sd.fields)
                        meta.paramKinds ~= dTypeToArgKind(field.type);
                } else {
                    meta.paramKinds ~= dTypeToArgKind(p.type);
                }
            }
            ffiMetas ~= meta;

            // Create a bodyless copy for the synthetic interface
            auto ifaceMethod = new FunctionDecl(method.location, method.name,
                method.returnType, method.parameters, null);
            ifaceMethod.objcSelector = selector;
            ifaceMethod.mangledName = sendImportName;
            ifaceMethod.isMethod = true;
            ifaceMethods ~= ifaceMethod;
        }

        // Inherit methods from parent ObjC interface (e.g., NSObject's alloc, init)
        // so callers can use MyClass.alloc().init() etc.
        if (auto parentIface = superName in objcInterfaces) {
            foreach (parentMethod; (*parentIface).methods) {
                // Don't override methods the class defines itself
                bool overridden = false;
                foreach (m; ifaceMethods) {
                    if (m.name == parentMethod.name) { overridden = true; break; }
                }
                if (!overridden)
                    ifaceMethods ~= parentMethod;
            }
        }

        syntheticIface.methods = ifaceMethods;
        objcInterfaces[classDecl.name] = syntheticIface;

        objcClassMetas ~= classMeta;
    }

    /// Register a bodyless ObjC class method as an ObjC send import.
    /// This handles methods like `static MyClass myAlloc() @selector("alloc")` —
    /// they have no WASM body but need to be callable via objc_msgSend.
    private void collectObjCClassSendMethod(ClassDecl classDecl, FunctionDecl method,
                                             string selector, ref FunctionDecl[] ifaceMethods) {
        // Resolve ObjC interface types in parameters
        resolveObjCUserType(cast(UserType)method.returnType);
        foreach (p; method.parameters) {
            resolveObjCUserType(cast(UserType)p.type);
        }

        // Detect struct return type
        auto resolvedRet = method.returnType.resolve();
        if (auto ut = cast(UserType)resolvedRet) {
            if (!ut.declaration) ut.ensureResolved(symbolTable);
        }
        auto retStructDecl = resolvedRet.asStruct();
        bool isStructReturn = retStructDecl !is null;

        // Build WASM signature: (receiver:i64, selector:i64, [result_ptr:i32], ...user_params)
        FuncSig sig;
        sig.params ~= ValType.i64;  // receiver
        sig.params ~= ValType.i64;  // selector
        if (isStructReturn) {
            sig.params ~= ValType.i32;  // hidden result pointer
        }
        foreach (p; method.parameters) {
            auto resolved = p.type.resolve();
            if (auto ut = cast(UserType)resolved) {
                if (!ut.declaration) ut.ensureResolved(symbolTable);
            }
            if (auto structDecl = resolved.asStruct()) {
                foreach (field; structDecl.fields)
                    sig.params ~= dTypeToValType(field.type);
            } else {
                sig.params ~= dTypeToValType(p.type);
            }
        }

        if (isStructReturn) {
            // No WASM return — caller uses the result pointer
        } else {
            bool isVoid = isVoidType(method.returnType);
            if (!isVoid) {
                sig.results = [dTypeToValType(method.returnType)];
            }
        }

        string sendImportName = "__objc_send_" ~ classDecl.name ~ "_" ~ method.name;

        uint tIdx;
        if (auto existing = sig in typeIndex) {
            tIdx = *existing;
        } else {
            tIdx = cast(uint)types.length;
            types ~= sig;
            typeIndex[sig] = tIdx;
        }

        ImportInfo info;
        info.moduleName = "ffi";
        info.fieldName = sendImportName;
        info.typeIndex = tIdx;
        importIndex[sendImportName] = cast(uint)imports.length;
        imports ~= info;

        FFIMeta meta;
        meta.name = sendImportName;
        meta.nativeName = "objc_msgSend";
        if (isStructReturn) {
            meta.retKind = ArgKind.RET_STRUCT;
            meta.paramKinds = [ArgKind.ARG_I64, ArgKind.ARG_I64, ArgKind.ARG_PTR];
            assert(retStructDecl.layoutComputed,
                "ObjC struct return " ~ retStructDecl.name ~ ": layout not computed");
            meta.retStructSize = cast(uint)retStructDecl.aggregateSize_;
            foreach (field; retStructDecl.fields)
                meta.retStructFieldKinds ~= dTypeToArgKind(field.type);
        } else {
            bool isVoid = isVoidType(method.returnType);
            meta.retKind = isVoid ? ArgKind.RET_VOID : dTypeToArgKind(method.returnType);
            meta.paramKinds = [ArgKind.ARG_I64, ArgKind.ARG_I64];
        }
        foreach (p; method.parameters) {
            auto resolved = p.type.resolve();
            if (auto structDecl = resolved.asStruct()) {
                foreach (field; structDecl.fields)
                    meta.paramKinds ~= dTypeToArgKind(field.type);
            } else {
                meta.paramKinds ~= dTypeToArgKind(p.type);
            }
        }
        ffiMetas ~= meta;

        method.mangledName = sendImportName;

        // Add to synthetic interface for caller dispatch
        auto ifaceMethod = new FunctionDecl(method.location, method.name,
            method.returnType, method.parameters, null);
        ifaceMethod.objcSelector = selector;
        ifaceMethod.mangledName = sendImportName;
        ifaceMethod.isMethod = true;
        ifaceMethod.isStatic = method.isStatic;
        ifaceMethods ~= ifaceMethod;
    }

    /// Build ObjC type encoding string for a method signature.
    /// Format: ret_type "@" ":" param1_type param2_type ...
    private static string buildObjCTypeEncoding(FunctionDecl method) {
        char[] enc;

        // Return type
        enc ~= typeToObjCEncoding(method.returnType);

        // self (@) and _cmd (:) are always present
        enc ~= '@';
        enc ~= ':';

        // User parameters
        foreach (p; method.parameters) {
            enc ~= typeToObjCEncoding(p.type);
        }

        return cast(string)enc;
    }

    /// Map a D type to its ObjC type encoding character
    private static char typeToObjCEncoding(Type t) {
        t = t.resolve();

        if (auto bt = cast(BasicType)t) {
            final switch (bt.kind) with (BasicType.Kind) {
                case Bool: return 'B';
                case Char: return 'c';
                case Int8: return 'c';
                case UInt8: return 'C';
                case Int16: return 's';
                case UInt16: return 'S';
                case Int32: return 'i';
                case UInt32: return 'I';
                case Int64: return 'q';
                case UInt64: return 'Q';
                case Float32: return 'f';
                case Float64: return 'd';
                case Void: return 'v';
            }
        }

        // ObjC interface / class types → '@' (object pointer)
        if (auto ut = cast(UserType)t) {
            if (auto ifaceDecl = cast(InterfaceDecl)ut.declaration) {
                if (ifaceDecl.isObjC) return '@';
            }
            if (auto classDecl = cast(ClassDecl)ut.declaration) {
                if (classDecl.isObjC) return '@';
            }
        }

        // Pointer types → '^' + pointee (simplified to '@' for id)
        if (cast(PointerType)t) return '^';

        // Default: treat as object pointer
        return '@';
    }

    /// Ensure objc_getClass and sel_registerName are registered as FFI imports
    private void ensureObjCHelpers() {
        if (objcHelpersAdded) return;
        objcHelpersAdded = true;

        addObjCHelperImport("objc_getClass", [ValType.i32], [ValType.i64],
                            [ArgKind.ARG_PTR], ArgKind.ARG_I64);
        addObjCHelperImport("sel_registerName", [ValType.i32], [ValType.i64],
                            [ArgKind.ARG_PTR], ArgKind.ARG_I64);
    }

    private void addObjCHelperImport(string name, ValType[] wasmParams, ValType[] wasmResults,
                                     ArgKind[] ffiParams, ArgKind ffiRet) {
        if (name in importIndex) return;

        FuncSig sig;
        sig.params = wasmParams;
        sig.results = wasmResults;

        uint tIdx;
        if (auto existing = sig in typeIndex) {
            tIdx = *existing;
        } else {
            tIdx = cast(uint)types.length;
            types ~= sig;
            typeIndex[sig] = tIdx;
        }

        ImportInfo info;
        info.moduleName = "ffi";
        info.fieldName = name;
        info.typeIndex = tIdx;
        importIndex[name] = cast(uint)imports.length;
        imports ~= info;

        FFIMeta meta;
        meta.name = name;
        meta.retKind = ffiRet;
        meta.paramKinds = ffiParams.dup;
        ffiMetas ~= meta;
    }

    /// Register a null-terminated C string in the data section, return its offset
    package uint registerCString(string s) {
        string key = s ~ "\0";
        if (auto existing = key in cStringOffsets) {
            return *existing;
        }
        uint offset = addData(cast(ubyte[])key.dup);
        cStringOffsets[key] = offset;
        return offset;
    }

    /// Resolve a UserType to an ObjC interface declaration if possible.
    /// Uses ensureResolved (symbol table) as primary, objcInterfaces map as fallback.
    private void resolveObjCUserType(UserType ut) {
        if (ut is null || ut.declaration !is null) return;
        ut.ensureResolved(symbolTable);
        if (!ut.declaration) {
            if (auto iface = ut.name in objcInterfaces)
                ut.declaration = *iface;
        }
    }

    /// Map a D Type to FFI ArgKind for marshaling metadata
    private static ArgKind dTypeToArgKind(Type t) {
        t = t.resolve();

        if (cast(PointerType) t)
            return ArgKind.ARG_PTR;

        if (cast(ArrayType) t)
            return ArgKind.ARG_PTR;

        if (auto ut = cast(UserType) t) {
            if (auto ifaceDecl = cast(InterfaceDecl)ut.declaration) {
                if (ifaceDecl.isObjC) return ArgKind.ARG_I64;
            }
            if (auto classDecl = cast(ClassDecl)ut.declaration) {
                if (classDecl.isObjC) return ArgKind.ARG_I64;
            }
            return ArgKind.ARG_PTR;
        }

        auto basic = cast(BasicType) t;
        if (!basic)
            return ArgKind.ARG_I32;

        final switch (basic.kind) {
            case BasicType.Kind.Int64:
            case BasicType.Kind.UInt64:
                return ArgKind.ARG_I64;
            case BasicType.Kind.Float32:
                return ArgKind.ARG_F32;
            case BasicType.Kind.Float64:
                return ArgKind.ARG_F64;
            case BasicType.Kind.Bool:
            case BasicType.Kind.Int8:
            case BasicType.Kind.Int16:
            case BasicType.Kind.Int32:
            case BasicType.Kind.UInt8:
            case BasicType.Kind.UInt16:
            case BasicType.Kind.UInt32:
            case BasicType.Kind.Char:
            case BasicType.Kind.Void:
                return ArgKind.ARG_I32;
        }
    }
    
    private void collectFunction(FunctionDecl decl) {
        // Skip forward declarations (no body) — only the real definition is emitted
        if (decl.body_ is null) {
            return;
        }

        // Skip template declarations — only instantiated functions are emitted
        if (decl.isTemplate) {
            return;
        }

        // Skip methods — they are collected via collectStructMethods/collectClassMethods
        // when their parent StructDecl/ClassDecl is processed (which sets structParent/classParent)
        if (decl.isMethod && decl.parent !is null) {
            return;
        }

        // In module output mode, skip CTFE-only functions (they run at compile time only).
        // In CTFE mode, compile everything — host functions are linked via wasm3 imports.
        if (!ctfeMode && isCtfeOnlyFunction(decl)) {
            return;
        }
        
        // Resolve return type if needed
        if (auto ut = cast(UserType)decl.returnType)
            ut.ensureResolved(symbolTable);
        
        // Scan for slice types to enable array support (__alloc, etc.)
        scanForSliceTypes(decl);

        // Collect methods from inner struct declarations in the function body
        collectInnerStructs(decl.body_);
        
        // Build signature via ParamLayout
        auto layout = buildLayout(decl, false, decl.name == "main");
        uint tIdx = registerSignature(layout);

        // Compute mangled name using module path from symbol table
        if (!decl.mangledName) {
            if (symbolTable.modulePath.length > 0) {
                import codegen.mangle : computeMangledName;
                decl.mangledName = computeMangledName(symbolTable.modulePath, decl);
            } else {
                decl.mangledName = decl.name;
            }
        }

        // Add function
        FuncInfo info;
        info.name = decl.mangledName;
        info.exportName = decl.name;  // Bare name for WASM exports
        info.typeIndex = tIdx;
        info.decl = decl;
        info.exported = true;  // Export all for now
        info.paramLayout = layout;

        funcIndex[decl.mangledName] = cast(uint)functions.length;
        // Also register bare name for backward-compatible lookups.
        // This will be removed when all call sites use mangled names.
        if (decl.name != decl.mangledName && decl.name !in funcIndex)
            funcIndex[decl.name] = cast(uint)functions.length;
        functions ~= info;
    }

    /// Resolve a bare function name to its WASM export name (mangled).
    /// Throws if no matching entry point is found.
    string resolveExportName(string bareName) const {
        foreach (ref f; functions) {
            if (f.exportName == bareName)
                return f.name;
        }
        throw new Exception("Entry point not found: " ~ bareName);
    }

    /**
     * Check if a type can be emitted to WASM (basic types only for now)
     */
    package bool isVoidType(Type t) {
        t = t.resolve();
        auto basic = cast(BasicType)t;
        return basic && basic.kind == BasicType.Kind.Void;
    }
    
    /**
     * Check if a return type requires hidden __result parameter
     * (structs and static arrays are too large to return in a register)
     */
    bool isLargeReturnType(Type t) {
        if (t is null) return false;
        t = t.resolve();

        // Ensure UserType is resolved before checking
        if (auto userType = cast(UserType)t) {
            if (!userType.declaration) {
                auto sym = symbolTable.lookupGlobalSymbol(userType.name);
                if (sym && sym.kind == SymbolKind.Type) {
                    userType.declaration = sym.declaration;
                }
            }
        }

        return t.isLargeReturn();
    }
    
    /**
     * Scan a function for slice/array types to enable array support
     */
    private void scanForSliceTypes(FunctionDecl decl) {
        if (!decl.body_) return;
        scanStatementForSliceTypes(decl.body_);
    }
    
    private void scanStatementForSliceTypes(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                scanStatementForSliceTypes(s);
            }
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            if (cast(ArrayType)varDecl.type) {
                needsArraySupport = true;
            }
            if (varDecl.initializer) {
                scanExpressionForCTFECalls(varDecl.initializer);
                scanExpressionForNewExpr(varDecl.initializer);
            }
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            scanStatementForSliceTypes(ifStmt.thenStatement);
            if (ifStmt.elseStatement) {
                scanStatementForSliceTypes(ifStmt.elseStatement);
            }
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            scanStatementForSliceTypes(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            if (forStmt.init) scanStatementForSliceTypes(forStmt.init);
            if (forStmt.body_) scanStatementForSliceTypes(forStmt.body_);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            scanExpressionForCTFECalls(exprStmt.expression);
            scanExpressionForNewExpr(exprStmt.expression);
        } else if (auto returnStmt = cast(ReturnStatement)stmt) {
            if (returnStmt.value) {
                scanExpressionForCTFECalls(returnStmt.value);
                scanExpressionForNewExpr(returnStmt.value);
            }
        } else if (auto structStmt = cast(StructDeclarationStatement)stmt) {
            // Scan inner struct methods for slice types too
            foreach (member; structStmt.structDecl.members) {
                if (auto funcDecl = cast(FunctionDecl)member) {
                    scanForSliceTypes(funcDecl);
                }
            }
        } else if (cast(BreakStatement)stmt || cast(ContinueStatement)stmt) {
            // No expressions to scan
        } else if (auto mixinStmt = cast(MixinStatement)stmt) {
            if (mixinStmt.isExpanded) {
                foreach (s; mixinStmt.expandedStatements) {
                    scanStatementForSliceTypes(s);
                }
            }
        } else if (auto tryStmt = cast(TryStatement)stmt) {
            scanStatementForSliceTypes(tryStmt.tryBody);
            foreach (c; tryStmt.catches)
                scanStatementForSliceTypes(c.body_);
            if (tryStmt.finallyBody !is null)
                scanStatementForSliceTypes(tryStmt.finallyBody);
        } else {
            assert(0, "scanStatementForSliceTypes: unhandled statement type: " ~ typeid(stmt).name);
        }
    }

    /// Scan an expression tree for NewExpression to enable __alloc
    private void scanExpressionForNewExpr(Expression expr) {
        if (needsArraySupport) return;  // Already enabled
        if (auto newExpr = cast(NewExpression)expr) {
            if (!newExpr.stackPromoted)  // stack-promoted new doesn't need __alloc
                needsArraySupport = true;
        } else if (auto call = cast(CallExpression)expr) {
            foreach (arg; call.arguments)
                scanExpressionForNewExpr(arg);
        } else if (auto binExpr = cast(BinaryExpression)expr) {
            scanExpressionForNewExpr(binExpr.left);
            scanExpressionForNewExpr(binExpr.right);
        } else if (auto unaryExpr = cast(UnaryExpression)expr) {
            scanExpressionForNewExpr(unaryExpr.operand);
        }
    }

    /**
     * Collect methods from inner struct declarations found in function bodies.
     */
    private void collectInnerStructs(Statement stmt) {
        if (stmt is null) return;
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                collectInnerStructs(s);
            }
        } else if (auto structStmt = cast(StructDeclarationStatement)stmt) {
            collectStructMethods(structStmt.structDecl);
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            collectInnerStructs(ifStmt.thenStatement);
            if (ifStmt.elseStatement) collectInnerStructs(ifStmt.elseStatement);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            collectInnerStructs(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            if (forStmt.init) collectInnerStructs(forStmt.init);
            if (forStmt.body_) collectInnerStructs(forStmt.body_);
        } else if (auto tryStmt = cast(TryStatement)stmt) {
            collectInnerStructs(tryStmt.tryBody);
            foreach (c; tryStmt.catches)
                collectInnerStructs(c.body_);
            if (tryStmt.finallyBody !is null)
                collectInnerStructs(tryStmt.finallyBody);
        }
    }

    /**
     * Scan an expression for calls to CTFE-only functions.
     * For __writeln, we pre-expand to the typed __ctfe_write_* imports.
     */
    private void scanExpressionForCTFECalls(Expression expr) {
        if (auto call = cast(CallExpression)expr) {
            if (auto ident = cast(IdentifierExpression)call.function_) {
                auto symbol = symbolTable.lookupSymbol(ident.name);
                if (symbol && symbol.isCTFEOnly) {
                    // Special case: __writeln is variadic, expand to typed imports
                    if (ident.name == "__writeln") {
                        // Register all __ctfe_write_* imports unconditionally —
                        // predicting which types are needed is fragile and unnecessary.
                        neededCTFEImports["__ctfe_write_newline"] = true;
                        neededCTFEImports["__ctfe_write_str"] = true;
                        neededCTFEImports["__ctfe_write_i32"] = true;
                        neededCTFEImports["__ctfe_write_i64"] = true;
                        neededCTFEImports["__ctfe_write_f64"] = true;
                        neededCTFEImports["__ctfe_write_bool"] = true;
                    } else {
                        neededCTFEImports[ident.name] = true;
                    }
                }
            }
            // Handle __ctfe_runtime.method() member calls
            if (auto member = cast(MemberExpression)call.function_) {
                if (auto obj = cast(IdentifierExpression)member.object) {
                    if (obj.name == "__ctfe_runtime") {
                        neededCTFEImports["__ctfe_runtime_" ~ member.memberName] = true;
                    }
                }
            }
            // Also scan arguments
            foreach (arg; call.arguments) {
                scanExpressionForCTFECalls(arg);
            }
        } else if (auto binary = cast(BinaryExpression)expr) {
            scanExpressionForCTFECalls(binary.left);
            scanExpressionForCTFECalls(binary.right);
        } else if (auto unary = cast(UnaryExpression)expr) {
            scanExpressionForCTFECalls(unary.operand);
        }
    }


    /**
     * Check if a function contains only CTFE intrinsics (like __writeln)
     * Such functions are evaluated at compile-time and don't need WASM emission
     */
    private bool isCtfeOnlyFunction(FunctionDecl decl) {
        if (!decl.body_) return false;
        // Functions using __ctfe_runtime are CTFE-only
        if (statementUsesCTFERuntime(decl.body_)) return true;
        return containsOnlyCtfeIntrinsics(decl.body_);
    }

    private bool statementUsesCTFERuntime(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                if (statementUsesCTFERuntime(s)) return true;
            }
            return false;
        }
        if (auto exprStmt = cast(ExpressionStatement)stmt) {
            if (auto call = cast(CallExpression)exprStmt.expression) {
                if (auto member = cast(MemberExpression)call.function_) {
                    if (auto obj = cast(IdentifierExpression)member.object) {
                        if (obj.name == "__ctfe_runtime") return true;
                    }
                }
            }
            return false;
        }
        if (auto returnStmt = cast(ReturnStatement)stmt) {
            return false;
        }
        if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            return false;
        }
        if (auto ifStmt = cast(IfStatement)stmt) {
            if (statementUsesCTFERuntime(ifStmt.thenStatement)) return true;
            if (ifStmt.elseStatement && statementUsesCTFERuntime(ifStmt.elseStatement)) return true;
            return false;
        }
        if (auto whileStmt = cast(WhileStatement)stmt) {
            return statementUsesCTFERuntime(whileStmt.body_);
        }
        if (auto forStmt = cast(ForStatement)stmt) {
            if (forStmt.init && statementUsesCTFERuntime(forStmt.init)) return true;
            if (forStmt.body_ && statementUsesCTFERuntime(forStmt.body_)) return true;
            return false;
        }
        if (cast(BreakStatement)stmt || cast(ContinueStatement)stmt
            || cast(MixinStatement)stmt || cast(StructDeclarationStatement)stmt) {
            return false;
        }
        if (auto tryStmt = cast(TryStatement)stmt) {
            if (statementUsesCTFERuntime(tryStmt.tryBody)) return true;
            foreach (c; tryStmt.catches)
                if (statementUsesCTFERuntime(c.body_)) return true;
            if (tryStmt.finallyBody !is null)
                if (statementUsesCTFERuntime(tryStmt.finallyBody)) return true;
            return false;
        }
        return false;
    }

    private bool containsOnlyCtfeIntrinsics(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            // Empty body is NOT ctfe-only — it's a valid runtime no-op function
            if (compound.statements.length == 0) return false;
            foreach (s; compound.statements) {
                if (!containsOnlyCtfeIntrinsics(s)) return false;
            }
            return true;
        }
        if (auto exprStmt = cast(ExpressionStatement)stmt) {
            if (auto call = cast(CallExpression)exprStmt.expression) {
                if (auto ident = cast(IdentifierExpression)call.function_) {
                    auto symbol = symbolTable.lookupSymbol(ident.name);
                    if (symbol && symbol.isCTFEOnly) return true;
                }
            }
            return false;  // Other expressions need WASM
        }
        if (auto returnStmt = cast(ReturnStatement)stmt) {
            return returnStmt.value is null;
        }
        if (cast(TryStatement)stmt) {
            return false;  // try/catch is not a CTFE intrinsic
        }
        // Any other statement type means this isn't a pure-intrinsic function
        return false;
    }
    
    /**
     * Convert D parameter list to WASM value types.
     * Interface params expand to 2 i32s (fat pointer).
     */
    package ValType[] paramsToValTypes(Parameter[] params) {
        ValType[] result;
        foreach (p; params) {
            if (p.type.asInterface()) {
                // Interface: fat pointer = 2 i32s
                result ~= ValType.i32;
                result ~= ValType.i32;
                continue;
            }
            result ~= dTypeToValType(p.type);
        }
        return result;
    }
    
    package ValType dTypeToValType(Type t) {
        // Unwrap TemplateParamType to the concrete bound type
        t = t.resolve();

        // Struct/class types are passed as i32 pointers; ObjC interfaces/classes as i64
        if (auto userType = cast(UserType)t) {
            if (auto ifaceDecl = cast(InterfaceDecl)userType.declaration) {
                if (ifaceDecl.isObjC) return ValType.i64;  // ObjC pointer = i64
            }
            if (auto classDecl = cast(ClassDecl)userType.declaration) {
                if (classDecl.isObjC) return ValType.i64;  // ObjC class pointer = i64
            }
            return ValType.i32;  // Pointer to struct/class
        }
        
        // Array/slice types are also passed as i32 pointers (to the slice struct)
        if (auto arrayType = cast(ArrayType)t) {
            return ValType.i32;  // Pointer to slice struct
        }

        // Explicit pointer types (T*) are i32 in WASM's 32-bit address space
        if (cast(PointerType)t) {
            return ValType.i32;
        }

        // Delegate/function types are passed as i32 pointer to {tableIdx, envPtr}
        if (cast(FunctionType)t) {
            return ValType.i32;
        }

        auto basic = cast(BasicType)t;
        if (!basic) {
            throw new EmitError("Non-basic types not yet supported", t.location);
        }
        
        final switch (basic.kind) {
            case BasicType.Kind.Bool:
            case BasicType.Kind.Int8:
            case BasicType.Kind.Int16:
            case BasicType.Kind.Int32:
            case BasicType.Kind.UInt8:
            case BasicType.Kind.UInt16:
            case BasicType.Kind.UInt32:
            case BasicType.Kind.Char:
                return ValType.i32;
                
            case BasicType.Kind.Int64:
            case BasicType.Kind.UInt64:
                return ValType.i64;
                
            case BasicType.Kind.Float32:
                return ValType.f32;
                
            case BasicType.Kind.Float64:
                return ValType.f64;
                
            case BasicType.Kind.Void:
                return ValType.i32;  // Placeholder, caller should check isVoidType
        }
    }
    
    /**
     * Get or create a type index for a method signature.
     * Used for interface dispatch where we need the type signature.
     */
    package uint getOrCreateMethodType(FunctionDecl method) {
        auto layout = buildLayout(method, true, false);
        return registerSignature(layout);
    }

    /**
     * Get or create a type index for a delegate call signature.
     * The signature includes the hidden __env parameter (i32) as first param,
     * followed by the user-visible parameter types, matching the lifted lambda's signature.
     */
    package uint getOrCreateDelegateCallType(FunctionDecl liftedFunc) {
        // The lifted function already has __env as its first param,
        // so just build its layout as a non-method, non-main function.
        auto layout = buildLayout(liftedFunc, false, false);
        return registerSignature(layout);
    }

    /**
     * Get or create a type index for a delegate call from its FunctionType.
     * Used when calling delegate parameters (no lifted function available).
     * Signature: (__env: i32, user_params...) -> result
     */
    package uint getOrCreateDelegateCallTypeFromFuncType(FunctionType funcType) {
        FuncSig sig;
        // __env is first param
        sig.params ~= ValType.i32;
        // User params
        foreach (pt; funcType.parameterTypes)
            sig.params ~= dTypeToValType(pt);
        // Return type
        if (!isVoidType(funcType.returnType))
            sig.results ~= dTypeToValType(funcType.returnType);

        if (auto existing = sig in typeIndex)
            return *existing;
        auto tIdx = cast(uint)types.length;
        types ~= sig;
        typeIndex[sig] = tIdx;
        return tIdx;
    }
    
    //==========================================================================
    // Array Support Built-ins
    //==========================================================================
    
    /**
     * Add built-in functions for array support:
     * - $heap_ptr global (mutable i32)
     * - $alloc(size: i32) -> i32: bump allocator
     * - $string_concat(s1: i32, s2: i32) -> i32: concatenate two arrays
     */
    private void addArrayBuiltins() {
        // Add heap_ptr global - initialized after data section is complete
        heapPtrGlobal = cast(uint)globals.length;
        GlobalInfo heapPtr;
        heapPtr.type = ValType.i32;
        heapPtr.mutable = true;
        heapPtr.initValue = 0;  // Will be updated after data section layout
        heapPtr.name = "__heap_ptr";
        globals ~= heapPtr;
        
        // Add $alloc function type: (i32) -> i32
        FuncSig allocSig;
        allocSig.params = [ValType.i32];
        allocSig.results = [ValType.i32];
        
        uint allocTypeIdx;
        if (auto existing = allocSig in typeIndex) {
            allocTypeIdx = *existing;
        } else {
            allocTypeIdx = cast(uint)types.length;
            types ~= allocSig;
            typeIndex[allocSig] = allocTypeIdx;
        }
        
        // Add $alloc function
        allocFuncIndex = cast(uint)functions.length;
        FuncInfo allocFunc;
        allocFunc.name = "__alloc";
        allocFunc.typeIndex = allocTypeIdx;
        allocFunc.decl = null;  // Built-in, no decl
        allocFunc.exported = true;  // Export for debugging
        funcIndex["__alloc"] = allocFuncIndex;
        functions ~= allocFunc;
        
        // Add $string_concat function type: (i32, i32) -> i32
        FuncSig concatSig;
        concatSig.params = [ValType.i32, ValType.i32];
        concatSig.results = [ValType.i32];
        
        uint concatTypeIdx;
        if (auto existing = concatSig in typeIndex) {
            concatTypeIdx = *existing;
        } else {
            concatTypeIdx = cast(uint)types.length;
            types ~= concatSig;
            typeIndex[concatSig] = concatTypeIdx;
        }
        
        // Add $string_concat function
        concatFuncIndex = cast(uint)functions.length;
        FuncInfo concatFunc;
        concatFunc.name = "__array_concat";
        concatFunc.typeIndex = concatTypeIdx;
        concatFunc.decl = null;  // Built-in
        concatFunc.exported = true;
        funcIndex["__array_concat"] = concatFuncIndex;
        functions ~= concatFunc;
        
        hasBuiltins = true;
    }

    /**
     * Add arena built-in functions for scope-based memory management:
     * - $arena_base global (mutable i32, points to root ArenaHeader)
     * - $arena_wm_top global (mutable i32, watermark stack top index)
     * - $arena_alloc(arena: i32, size: i32) -> i32: bump allocator within arena
     * - $arena_new(arena: i32) -> void: push watermark (save current offset)
     * - $arena_drop(arena: i32) -> void: pop watermark (restore offset)
     *
     * Arena memory layout (set up at finalizeArenaBase):
     *   arenaBase+0:    ArenaHeader (16 bytes: offset, end, parent, save_count)
     *   arenaBase+16:   Watermark stack (256 × 4 = 1024 bytes)
     *   arenaBase+1040: Allocation space starts here
     */
    private void addArenaBuiltins() {
        import codegen.wasm.types : ARENA_HEADER_SIZE, ARENA_METADATA_SIZE;

        // Add arena_base global — initialized after data section layout
        arenaBaseGlobal = cast(uint)globals.length;
        GlobalInfo arenaBase;
        arenaBase.type = ValType.i32;
        arenaBase.mutable = true;
        arenaBase.initValue = 0;  // Finalized in finalizeArenaBase()
        arenaBase.name = "__arena_base";
        globals ~= arenaBase;

        // Add watermark stack top global — index into watermark stack (0 = empty)
        arenaWatermarkGlobal = cast(uint)globals.length;
        GlobalInfo wmTop;
        wmTop.type = ValType.i32;
        wmTop.mutable = true;
        wmTop.initValue = 0;  // Starts empty
        wmTop.name = "__arena_wm_top";
        globals ~= wmTop;

        // __arena_alloc(arena: i32, size: i32) -> i32
        FuncSig arenaAllocSig;
        arenaAllocSig.params = [ValType.i32, ValType.i32];
        arenaAllocSig.results = [ValType.i32];

        uint arenaAllocTypeIdx;
        if (auto existing = arenaAllocSig in typeIndex) {
            arenaAllocTypeIdx = *existing;
        } else {
            arenaAllocTypeIdx = cast(uint)types.length;
            types ~= arenaAllocSig;
            typeIndex[arenaAllocSig] = arenaAllocTypeIdx;
        }

        arenaAllocFuncIndex = cast(uint)functions.length;
        FuncInfo arenaAllocFunc;
        arenaAllocFunc.name = "__arena_alloc";
        arenaAllocFunc.typeIndex = arenaAllocTypeIdx;
        arenaAllocFunc.decl = null;
        arenaAllocFunc.exported = true;
        funcIndex["__arena_alloc"] = arenaAllocFuncIndex;
        functions ~= arenaAllocFunc;

        // __arena_new(arena: i32) -> void
        FuncSig arenaNewSig;
        arenaNewSig.params = [ValType.i32];
        arenaNewSig.results = [];

        uint arenaNewTypeIdx;
        if (auto existing = arenaNewSig in typeIndex) {
            arenaNewTypeIdx = *existing;
        } else {
            arenaNewTypeIdx = cast(uint)types.length;
            types ~= arenaNewSig;
            typeIndex[arenaNewSig] = arenaNewTypeIdx;
        }

        arenaNewFuncIndex = cast(uint)functions.length;
        FuncInfo arenaNewFunc;
        arenaNewFunc.name = "__arena_new";
        arenaNewFunc.typeIndex = arenaNewTypeIdx;
        arenaNewFunc.decl = null;
        arenaNewFunc.exported = true;
        funcIndex["__arena_new"] = arenaNewFuncIndex;
        functions ~= arenaNewFunc;

        // __arena_drop(arena: i32) -> void
        arenaDropFuncIndex = cast(uint)functions.length;
        FuncInfo arenaDropFunc;
        arenaDropFunc.name = "__arena_drop";
        arenaDropFunc.typeIndex = arenaNewTypeIdx;  // Same signature: (i32) -> void
        arenaDropFunc.decl = null;
        arenaDropFunc.exported = true;
        funcIndex["__arena_drop"] = arenaDropFuncIndex;
        functions ~= arenaDropFunc;

        hasArenaBuiltins = true;
    }

    /**
     * Finalize the arena base address.
     * Arena lives on page 1+ (65536+), separate from shadow stack (page 0).
     * This allows the arena to grow via memory.grow without conflicting with the stack.
     */
    private void finalizeArenaBase() {
        import codegen.wasm.types : ARENA_METADATA_SIZE;

        if (!hasArenaBuiltins) return;

        // Arena starts at page 1 boundary — completely separate from page 0
        // (data section, heap, shadow stack all live in page 0)
        uint arenaStart = 65536;
        uint arenaEnd = memoryPages * 65536;  // initial memory ceiling

        globals[arenaBaseGlobal].initValue = arenaStart;

        // Initialize the root ArenaHeader in the data section:
        // offset = arenaStart + ARENA_METADATA_SIZE (first allocation address)
        // end = arenaEnd (current memory ceiling — __arena_alloc grows via memory.grow)
        // parent = 0 (root, no parent)
        // save_count = 0
        uint allocStart = arenaStart + ARENA_METADATA_SIZE;
        ubyte[16] headerData;
        // offset field (bump pointer starts at allocation space)
        headerData[0] = cast(ubyte)(allocStart & 0xFF);
        headerData[1] = cast(ubyte)((allocStart >> 8) & 0xFF);
        headerData[2] = cast(ubyte)((allocStart >> 16) & 0xFF);
        headerData[3] = cast(ubyte)((allocStart >> 24) & 0xFF);
        // end field (memory ceiling — arena_alloc grows memory when exceeded)
        headerData[4] = cast(ubyte)(arenaEnd & 0xFF);
        headerData[5] = cast(ubyte)((arenaEnd >> 8) & 0xFF);
        headerData[6] = cast(ubyte)((arenaEnd >> 16) & 0xFF);
        headerData[7] = cast(ubyte)((arenaEnd >> 24) & 0xFF);
        // parent field (0 = root)
        headerData[8..12] = 0;
        // save_count field (0)
        headerData[12..16] = 0;

        dataEntries ~= DataEntry(arenaStart, headerData[].dup);
    }

    /**
     * Finalize the heap pointer after data section is laid out
     */
    private void finalizeHeapPtr() {
        if (needsArraySupport) {
            // Align to 8 bytes
            uint heapStart = (nextDataOffset + MEMORY_ALIGNMENT - 1) & ~(MEMORY_ALIGNMENT - 1);
            globals[heapPtrGlobal].initValue = heapStart;
        }
    }
    
    /**
     * Add shadow stack pointer global.
     * The shadow stack lives in page 0, growing downward from 65536.
     * Arena lives on page 1+ and grows upward via memory.grow — no collision possible.
     */
    private void addShadowStackGlobal() {
        spGlobal = cast(uint)globals.length;
        GlobalInfo sp;
        sp.type = ValType.i32;
        sp.mutable = true;
        sp.initValue = 65536;  // Top of page 0 (stack grows down, arena grows up from page 1)
        sp.name = "__sp";
        globals ~= sp;
    }
    
    /**
     * Pre-allocate the exception slot array in the data section.
     * Must be called BEFORE finalizeHeapPtr() so the heap pointer accounts for this data.
     */
    private void allocateExceptionSlotArray() {
        import codegen.wasm.types : EXCEPTION_ARRAY_SIZE;
        exceptionArrayOffset = addData(new ubyte[](EXCEPTION_ARRAY_SIZE));
    }

    /**
     * Add exception handling globals.
     * Two mutable globals: __exception_pending (hot-path check) and __exception_depth (slot index).
     * Exception data (kind, file, line, col, value) lives in pre-allocated slots in linear memory.
     */
    private void addExceptionGlobals() {
        exceptionPendingGlobal = cast(uint)globals.length;
        GlobalInfo pending;
        pending.type = ValType.i32;
        pending.mutable = true;
        pending.initValue = 0;
        pending.name = "__exception_pending";
        globals ~= pending;

        exceptionDepthGlobal = cast(uint)globals.length;
        GlobalInfo depth;
        depth.type = ValType.i32;
        depth.mutable = true;
        depth.initValue = 0;
        depth.name = "__exception_depth";
        globals ~= depth;
    }

    /**
     * Initialize call stack tracking data section.
     * Used for CTFE error stack traces (milestone 144).
     * 
     * Memory layout (first 2KB):
     *   0-3:      depth (u32) - current stack depth, starts at 0
     *   4-7:      maxDepth (u32) - constant 64
     *   8-1543:   frames[64] (24 bytes each)
     *   1544-2047: String pool for function/file names
     * 
     * Note: depth is stored in memory (not a global) so it can be read
     * by the host after a trap.
     */
    private void addCallStackGlobal() {
        import codegen.wasm.types : CALL_STACK_DEPTH_OFFSET, CALL_STACK_MAX_DEPTH_OFFSET,
                                    CALL_STACK_MAX_FRAMES;
        
        // Initialize depth in data section (starts at 0)
        ubyte[4] depthData = [0, 0, 0, 0];
        dataEntries ~= DataEntry(CALL_STACK_DEPTH_OFFSET, depthData[].dup);
        
        // Initialize maxDepth in data section (constant 64)
        ubyte[4] maxDepthData;
        uint maxDepth = CALL_STACK_MAX_FRAMES;
        maxDepthData[0] = cast(ubyte)(maxDepth & 0xFF);
        maxDepthData[1] = cast(ubyte)((maxDepth >> 8) & 0xFF);
        maxDepthData[2] = cast(ubyte)((maxDepth >> 16) & 0xFF);
        maxDepthData[3] = cast(ubyte)((maxDepth >> 24) & 0xFF);
        dataEntries ~= DataEntry(CALL_STACK_MAX_DEPTH_OFFSET, maxDepthData[].dup);
        
        // callStackDepthGlobal is no longer used - depth is in memory
        // But we keep the variable for compatibility (set to invalid value)
        callStackDepthGlobal = uint.max;
    }
    
    /**
     * Register a function's frame info for call stack tracking.
     * Stores the function name and source location in the string pool.
     * Returns the frame info with offsets into the data section.
     */
    package CallStackFrameInfo registerCallStackFrame(string funcName, string fileName, uint line, uint column) {
        import codegen.wasm.types : CALL_STACK_STRING_POOL_OFFSET, MEMORY_RESERVED;
        
        // Check if already registered
        if (auto existing = funcName in callStackFrameInfos) {
            return *existing;
        }
        
        // Add function name to string pool
        uint nameOffset = callStackStringPoolOffset;
        uint nameLen = cast(uint)funcName.length;
        
        // Ensure we don't overflow into the reserved area
        if (callStackStringPoolOffset + nameLen > MEMORY_RESERVED) {
            // Fall back to using regular data section
            nameOffset = addData(cast(ubyte[])funcName.dup);
        } else {
            dataEntries ~= DataEntry(nameOffset, cast(ubyte[])funcName.dup);
            callStackStringPoolOffset += nameLen;
            // Align to 4 bytes
            callStackStringPoolOffset = (callStackStringPoolOffset + 3) & ~3;
        }
        
        // Add file name to string pool  
        uint fileOffset = callStackStringPoolOffset;
        uint fileLen = cast(uint)fileName.length;
        
        if (callStackStringPoolOffset + fileLen > MEMORY_RESERVED) {
            fileOffset = addData(cast(ubyte[])fileName.dup);
        } else {
            dataEntries ~= DataEntry(fileOffset, cast(ubyte[])fileName.dup);
            callStackStringPoolOffset += fileLen;
            callStackStringPoolOffset = (callStackStringPoolOffset + 3) & ~3;
        }
        
        auto info = CallStackFrameInfo(nameOffset, nameLen, fileOffset, fileLen, line, column);
        callStackFrameInfos[funcName] = info;
        return info;
    }
    
    /**
     * Add imports for CTFE-only functions.
     * These are imported from the "ctfe" module and linked by the CTFE runtime.
     */
    private void addCTFEImports() {
        foreach (name; neededCTFEImports.byKey()) {
            // Build signature based on the function
            FuncSig sig;
            switch (name) {
                // Standalone debug function
                case "__ctfe_print_i32":
                    sig.params = [ValType.i32];
                    break;

                // Building blocks for __writeln
                case "__ctfe_write_i32":
                    sig.params = [ValType.i32];
                    break;
                case "__ctfe_write_i64":
                    sig.params = [ValType.i64];
                    break;
                case "__ctfe_write_str":
                    sig.params = [ValType.i32, ValType.i32];  // ptr, len
                    break;
                case "__ctfe_write_bool":
                    sig.params = [ValType.i32];
                    break;
                case "__ctfe_write_f64":
                    sig.params = [ValType.f64];
                    break;
                case "__ctfe_write_newline":
                    sig.params = [];
                    break;

                // __ctfe_runtime host functions
                case "__ctfe_runtime_alloc":
                    sig.params = [ValType.i32];    // size
                    sig.results = [ValType.i32];   // pointer
                    break;
                case "__ctfe_runtime_push":
                case "__ctfe_runtime_pop":
                    // no params, no results
                    break;
                case "__ctfe_runtime_remaining":
                    sig.results = [ValType.i32];   // remaining bytes
                    break;

                case "__writeln":
                    // Variadic - lowered to typed calls at emit time, don't import
                    continue;
                default:
                    // Unknown CTFE function - skip
                    continue;
            }
            
            // Get or create type index
            uint tIdx;
            if (auto existing = sig in typeIndex) {
                tIdx = *existing;
            } else {
                tIdx = cast(uint)types.length;
                types ~= sig;
                typeIndex[sig] = tIdx;
            }
            
            // Add as import from "ctfe" module
            ImportInfo info;
            info.moduleName = "ctfe";
            info.fieldName = name;
            info.typeIndex = tIdx;
            
            importIndex[name] = cast(uint)imports.length;
            imports ~= info;
        }
    }
    
    //==========================================================================
    // Index Stabilization (for incremental compilation)
    //==========================================================================
    
    /**
     * Sort types, functions, and imports for stable index assignment.
     * This ensures the same source code produces identical WASM indices
     * across compilations, enabling incremental compilation caching.
     */
    private void stabilizeIndices() {
        import std.algorithm : sort;
        
        // Build reverse mapping: old type index -> signature
        FuncSig[] oldTypes = types.dup;
        
        // 1. Sort types by canonical representation
        types.sort!((a, b) => funcSigKey(a) < funcSigKey(b));
        
        // Rebuild typeIndex with new indices
        typeIndex.clear();
        foreach (i, sig; types) {
            typeIndex[sig] = cast(uint)i;
        }
        
        // 2. Update function typeIndex references
        foreach (ref f; functions) {
            // Look up the signature using the OLD type index
            if (f.typeIndex < oldTypes.length) {
                auto sig = oldTypes[f.typeIndex];
                // Get the NEW type index for this signature
                f.typeIndex = typeIndex[sig];
            }
        }
        
        // 3. Update import typeIndex references
        foreach (ref imp; imports) {
            if (imp.typeIndex < oldTypes.length) {
                auto sig = oldTypes[imp.typeIndex];
                imp.typeIndex = typeIndex[sig];
            }
        }
        
        // 4. Sort functions by name
        functions.sort!((a, b) => a.name < b.name);
        
        // Rebuild funcIndex (mangled names + bare-name aliases)
        funcIndex.clear();
        foreach (i, ref f; functions) {
            funcIndex[f.name] = cast(uint)i;
            // Re-add bare-name alias for backward-compatible lookups
            if (f.exportName.length > 0 && f.exportName != f.name && f.exportName !in funcIndex)
                funcIndex[f.exportName] = cast(uint)i;
        }
        
        // 5. Sort imports by (module, field)
        imports.sort!((a, b) {
            if (a.moduleName != b.moduleName) return a.moduleName < b.moduleName;
            return a.fieldName < b.fieldName;
        });
        
        // Rebuild importIndex
        importIndex.clear();
        foreach (i, ref imp; imports) {
            importIndex[imp.fieldName] = cast(uint)i;
        }
        
        // 6. Update built-in function indices
        if (hasBuiltins) {
            if (auto idx = "__alloc" in funcIndex) {
                allocFuncIndex = *idx + cast(uint)imports.length;
            }
            if (auto idx = "__array_concat" in funcIndex) {
                concatFuncIndex = *idx + cast(uint)imports.length;
            }
        }
        if (hasArenaBuiltins) {
            if (auto idx = "__arena_alloc" in funcIndex) {
                arenaAllocFuncIndex = *idx + cast(uint)imports.length;
            }
            if (auto idx = "__arena_new" in funcIndex) {
                arenaNewFuncIndex = *idx + cast(uint)imports.length;
            }
            if (auto idx = "__arena_drop" in funcIndex) {
                arenaDropFuncIndex = *idx + cast(uint)imports.length;
            }
        }
    }
    
    /**
     * Build function table entries for virtual dispatch.
     * Called after stabilizeIndices() so we use the final sorted function indices.
     */
    private void buildVtables() {
        tableFunctions = [];
        
        foreach (classDecl; classesWithVtables) {
            // Assign tableBase = current position in table
            classDecl.tableBase = cast(uint)tableFunctions.length;
            
            // Add virtual methods in declaration order
            foreach (method; classDecl.virtualMethods) {
                // Use the method's mangledName (set during collectClassMethod)
                if (auto idx = method.mangledName in funcIndex) {
                    // funcIndex already includes import offset after stabilization
                    tableFunctions ~= cast(uint)imports.length + *idx;
                }
            }
            
            // Build itables for each interface this class implements
            buildItables(classDecl);
        }
    }
    
    /**
     * Build interface tables for a class.
     * Each interface gets its own itable with methods in interface order.
     * 
     * Packed itable_ptr design (same as class vtable_ptr, see codegen.target.VtablePacking):
     *   itable_ptr = (typeId << TYPE_ID_SHIFT) | itableBase
     */
    private void buildItables(ClassDecl classDecl) {
        foreach (ifaceType; classDecl.interfaces) {
            if (auto ifaceDecl = ifaceType.asInterface()) {
                // Assign typeId and generate TypeInfo if not already done
                if (ifaceDecl.typeId == 0) {
                    ifaceDecl.typeId = nextTypeId++;
                    generateInterfaceTypeInfo(ifaceDecl);
                }

                // Record itable base with packed typeId
                uint itableBase = cast(uint)tableFunctions.length;
                uint packedItablePtr = WasmVtablePacking.pack(ifaceDecl.typeId, itableBase);
                classDecl.itableBases[ifaceDecl.name] = packedItablePtr;

                // Add methods in interface's method order
                foreach (ifaceMethod; ifaceDecl.methods) {
                    // Find the implementing method in the class
                    auto implMethod = findImplementingMethod(classDecl, ifaceMethod.name);
                    if (implMethod) {
                        if (auto idx = implMethod.mangledName in funcIndex) {
                            tableFunctions ~= cast(uint)imports.length + *idx;
                        }
                    }
                }
            }
        }
    }
    
    /**
     * Generate TypeInfo for an interface in the data section.
     * TypeInfo is indexed by typeId for error messages.
     */
    private void generateInterfaceTypeInfo(InterfaceDecl ifaceDecl) {
        // Add interface name to data section
        uint nameOffset = addData(cast(ubyte[])ifaceDecl.name);
        uint nameLen = cast(uint)ifaceDecl.name.length;
        
        // Emit TypeInfo struct: {nameOffset, nameLen}
        ubyte[8] typeInfo;
        *cast(uint*)&typeInfo[0] = nameOffset;
        *cast(uint*)&typeInfo[4] = nameLen;
        ifaceDecl.typeInfoOffset = addData(typeInfo[]);
        
        // Track TypeInfo offset by typeId
        while (typeInfoOffsets.length <= ifaceDecl.typeId) {
            typeInfoOffsets ~= 0;
        }
        typeInfoOffsets[ifaceDecl.typeId] = ifaceDecl.typeInfoOffset;
    }
    
    /**
     * Find method implementing an interface method (searches class and base classes)
     */
    private FunctionDecl findImplementingMethod(ClassDecl classDecl, string methodName) {
        // Check class's own methods
        foreach (member; classDecl.members) {
            if (auto method = cast(FunctionDecl)member) {
                if (method.name == methodName && !method.isConstructor && !method.isDestructor) {
                    return method;
                }
            }
        }
        // Check base class
        if (classDecl.baseClassDecl) {
            return findImplementingMethod(classDecl.baseClassDecl, methodName);
        }
        return null;
    }
    
    /**
     * Collect lifted lambda functions from all function bodies.
     * Walks all collected functions, scans their bodies for FunctionLiteralExpression,
     * collects the lifted FunctionDecl, and adds it to the function table.
     */
    private void collectLiftedLambdas() {
        import ast.expressions : FunctionLiteralExpression;
        import codegen.mangle : computeMangledName;

        // Walk all functions that have bodies and scan for lambda expressions
        FunctionLiteralExpression[] lambdas;
        foreach (ref f; functions) {
            if (f.decl !is null && f.decl.body_ !is null) {
                scanForLambdas(f.decl.body_, lambdas);
            }
        }

        // Collect each lambda as a top-level function and register in table
        foreach (funcLit; lambdas) {
            auto lifted = funcLit.liftedFunction;
            if (lifted is null) continue;
            if (lifted.mangledName in funcIndex) continue;  // already collected

            // Assign mangled name
            lifted.mangledName = computeMangledName(symbolTable.modulePath, lifted);

            // Scan for slice types in the lifted body
            scanForSliceTypes(lifted);

            // Build WASM signature — the lifted function has __env as first param
            auto layout = buildLayout(lifted, false, false);
            uint tIdx = registerSignature(layout);

            FuncInfo info;
            info.name = lifted.mangledName;
            info.decl = lifted;
            info.typeIndex = tIdx;
            info.isImport = false;
            info.paramLayout = layout;
            info.lambdaExpr = funcLit;

            funcIndex[lifted.mangledName] = cast(uint)functions.length;
            functions ~= info;

            // Add to function table for call_indirect
            uint absIdx = cast(uint)imports.length + funcIndex[lifted.mangledName];
            lambdaTableIndex[lifted.mangledName] = cast(uint)tableFunctions.length;
            tableFunctions ~= absIdx;
        }
    }

    /// Recursively scan a statement tree for FunctionLiteralExpression nodes.
    private void scanForLambdas(Statement stmt, ref FunctionLiteralExpression[] result) {
        import ast.expressions : FunctionLiteralExpression;
        if (stmt is null) return;

        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements)
                scanForLambdas(s, result);
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            scanForLambdas(ifStmt.thenStatement, result);
            scanForLambdas(ifStmt.elseStatement, result);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            scanForLambdas(whileStmt.body_, result);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            scanForLambdas(forStmt.init, result);
            scanForLambdas(forStmt.body_, result);
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            scanExprForLambdas(varDecl.initializer, result);
        } else if (auto retStmt = cast(ReturnStatement)stmt) {
            scanExprForLambdas(retStmt.value, result);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            scanExprForLambdas(exprStmt.expression, result);
        } else if (auto tryStmt = cast(TryStatement)stmt) {
            scanForLambdas(tryStmt.tryBody, result);
            foreach (c; tryStmt.catches)
                scanForLambdas(c.body_, result);
            if (tryStmt.finallyBody !is null)
                scanForLambdas(tryStmt.finallyBody, result);
        }
        // Other statement types: no expressions containing lambdas
    }

    /// Recursively scan an expression for FunctionLiteralExpression nodes.
    private void scanExprForLambdas(Expression expr, ref FunctionLiteralExpression[] result) {
        import ast.expressions;
        if (expr is null) return;

        if (auto funcLit = cast(FunctionLiteralExpression)expr) {
            result ~= funcLit;
            return;
        }
        // Recurse into sub-expressions
        if (auto binExpr = cast(BinaryExpression)expr) {
            scanExprForLambdas(binExpr.left, result);
            scanExprForLambdas(binExpr.right, result);
        } else if (auto callExpr = cast(CallExpression)expr) {
            scanExprForLambdas(callExpr.function_, result);
            foreach (arg; callExpr.arguments)
                scanExprForLambdas(arg, result);
        } else if (auto assignExpr = cast(AssignmentExpression)expr) {
            scanExprForLambdas(assignExpr.left, result);
            scanExprForLambdas(assignExpr.right, result);
        } else if (auto castExpr = cast(CastExpression)expr) {
            scanExprForLambdas(castExpr.expression, result);
        } else if (auto unaryExpr = cast(UnaryExpression)expr) {
            scanExprForLambdas(unaryExpr.operand, result);
        } else if (auto throwExpr = cast(ThrowExpression)expr) {
            scanExprForLambdas(throwExpr.operand, result);
        }
    }

    /// Get the table index for a lifted lambda (for call_indirect).
    package uint getLambdaTableIndex(string mangledName) {
        if (auto idx = mangledName in lambdaTableIndex)
            return *idx;
        throw new Exception("Lambda not found in function table: " ~ mangledName);
    }

    /// Generate a canonical string key for a function signature (for sorting)
    private static string funcSigKey(FuncSig sig) {
        import std.conv : to;
        string key = "(";
        foreach (i, p; sig.params) {
            if (i > 0) key ~= ",";
            key ~= to!string(p);
        }
        key ~= ")->(";
        foreach (i, r; sig.results) {
            if (i > 0) key ~= ",";
            key ~= to!string(r);
        }
        key ~= ")";
        return key;
    }
    
    //==========================================================================
    // Header
    //==========================================================================
    
    private void emitHeader() {
        output.clear();
        // Magic: \0asm
        output ~= cast(ubyte[])[0x00, 0x61, 0x73, 0x6D];
        // Version: 1
        output ~= cast(ubyte[])[0x01, 0x00, 0x00, 0x00];
    }
    
    //==========================================================================
    // Section Helpers
    //==========================================================================
    
    private void emitSection(Section id, ubyte[] content) {
        output ~= cast(ubyte)id;
        leb128u(output, content.length);
        output ~= content;
    }
    
    //==========================================================================
    // Type Section
    //==========================================================================
    
    private void emitTypeSection() {
        if (auto content = buildTypeSection(types))
            emitSection(Section.type, content);
    }
    
    //==========================================================================
    // Import Section
    //==========================================================================
    
    private void emitImportSection() {
        if (auto content = buildImportSection(imports))
            emitSection(Section.import_, content);
    }
    
    //==========================================================================
    // Function Section
    //==========================================================================
    
    private void emitFunctionSection() {
        if (functions.length == 0) return;
        
        // Extract type indices from FuncInfo array
        auto typeIndices = functions.map!(f => f.typeIndex).array;
        if (auto content = buildFunctionSection(typeIndices))
            emitSection(Section.function_, content);
    }
    
    //==========================================================================
    // Table Section (for call_indirect / virtual dispatch)
    //==========================================================================
    
    private void emitTableSection() {
        if (tableFunctions.length == 0) return;
        
        // Build table section: one funcref table with enough slots
        Appender!(ubyte[]) content;
        
        // Number of tables: 1
        content ~= cast(ubyte)0x01;
        
        // Table type: funcref (0x70), limits
        content ~= cast(ubyte)0x70;  // funcref
        
        // Limits: has max (0x01), min, max
        uint tableSize = cast(uint)tableFunctions.length;
        content ~= cast(ubyte)0x01;  // has max flag
        leb128u(content, tableSize);  // min
        leb128u(content, tableSize);  // max
        
        emitSection(Section.table, content.data);
    }
    
    //==========================================================================
    // Element Section (populates function table)
    //==========================================================================
    
    private void emitElementSection() {
        if (tableFunctions.length == 0) return;
        
        // Build element section: initialize table[0..n] with function indices
        Appender!(ubyte[]) content;
        
        // Number of element segments: 1
        content ~= cast(ubyte)0x01;
        
        // Element segment:
        // - flags: 0x00 = active, table 0, offset expr
        content ~= cast(ubyte)0x00;
        
        // - offset: i32.const 0, end
        content ~= cast(ubyte)0x41;  // i32.const
        leb128s(content, 0);  // offset 0
        content ~= cast(ubyte)0x0B;  // end
        
        // - num functions
        leb128u(content, cast(uint)tableFunctions.length);
        
        // - function indices
        foreach (funcIdx; tableFunctions) {
            leb128u(content, funcIdx);
        }
        
        emitSection(Section.element, content.data);
    }
    
    //==========================================================================
    // Memory Section
    //==========================================================================
    
    private void emitMemorySection() {
        // Always emit memory for now (needed for data section)
        if (auto content = buildMemorySection(memoryPages))
            emitSection(Section.memory, content);
    }
    
    //==========================================================================
    // Global Section
    //==========================================================================
    
    private void emitGlobalSection() {
        if (globals.length == 0) return;
        
        // Convert to section builder's GlobalInfo format
        import codegen.wasm.sections.global : GlobalInfo_ = GlobalInfo;
        auto sectionGlobals = globals.map!(g => GlobalInfo_(g.type, g.mutable, g.initValue, g.initF64)).array;
        
        if (auto content = buildGlobalSection(sectionGlobals))
            emitSection(Section.global, content);
    }
    
    //==========================================================================
    // Export Section
    //==========================================================================
    
    private void emitExportSection() {
        // Build function exports
        FuncExport[] funcExports;
        foreach (i, f; functions) {
            if (f.exported) {
                // Export with mangled name
                funcExports ~= FuncExport(f.name, cast(uint)imports.length + cast(uint)i);
            }
        }
        
        // Build global exports
        GlobalExport[] globalExports;
        if (needsArraySupport) {
            globalExports ~= GlobalExport("__heap_ptr", heapPtrGlobal);
        }
        if (exceptionPendingGlobal < globals.length) {
            globalExports ~= GlobalExport("__exception_pending", exceptionPendingGlobal);
            globalExports ~= GlobalExport("__exception_depth", exceptionDepthGlobal);
        }
        
        if (auto content = buildExportSection(funcExports, needsMemory || needsArraySupport, globalExports))
            emitSection(Section.export_, content);
    }
    
    //==========================================================================
    // Code Section
    //==========================================================================
    
    private void emitCodeSection() {
        if (functions.length == 0) return;
        
        // Emit all function bodies
        ubyte[][] bodies;
        foreach (f; functions) {
            bodies ~= emitFunctionBody(f);
        }
        
        if (auto content = buildCodeSection(bodies))
            emitSection(Section.code, content);
    }
    
    private ubyte[] emitFunctionBody(FuncInfo f) {
        // Handle built-in functions — deterministic, not tracked in cache stats
        if (f.decl is null) {
            return emitBuiltinBody(f);
        }
        
        // Check code cache
        auto currentHash = computeFunctionHash(f);
        if (f.name in codeCache && f.name in sourceHashes) {
            if (sourceHashes[f.name] == currentHash) {
                // Cache hit - source unchanged
                cacheHits[f.name] = true;
                return codeCache[f.name].dup;
            }
        }
        
        // Cache miss - emit fresh
        Appender!(ubyte[]) body_;
        
        // Create context for this function
        auto ctx = new FuncContext(f, this);
        
        // Collect locals from function body
        if (f.decl.body_) {
            ctx.collectLocals(f.decl.body_);
        }
        
        // Finalize locals (adds savedSpLocal if struct locals exist)
        ctx.finalizeLocals();
        
        // Emit local declarations
        ctx.emitLocalDecls(body_);
        
        // Emit shadow stack prologue if needed
        ctx.emitPrologue(body_);

        // Save arena watermark at function entry
        ctx.emitArenaScopeCall(body_, true);

        // Emit body
        if (f.decl.body_) {
            ctx.emitStatement(body_, f.decl.body_);
        }

        // Restore arena watermark for implicit return
        ctx.emitArenaScopeCall(body_, false);

        // Emit shadow stack epilogue if needed (for implicit return)
        ctx.emitEpilogue(body_);

        // End opcode
        body_ ~= Op.end;

        // Store in cache for next time
        auto result = body_.data;
        codeCache[f.name] = result.dup;
        sourceHashes[f.name] = currentHash;
        
        return result;
    }
    
    /**
     * Emit body for built-in functions ($alloc, $string_concat)
     */
    private ubyte[] emitBuiltinBody(FuncInfo f) {
        Appender!(ubyte[]) body_;
        
        if (f.name == "__alloc") {
            // $alloc(size: i32) -> i32
            // Bump allocator: returns current heap_ptr, then advances it
            //
            // local 0 = size (parameter)
            // local 1 = result (current heap_ptr)
            //
            // result = heap_ptr
            // heap_ptr = heap_ptr + align(size, 8)
            // return result
            
            leb128u(body_, 1);  // 1 local group
            leb128u(body_, 1);  // 1 local
            body_ ~= cast(ubyte)ValType.i32;  // of type i32
            
            // result = global.get $heap_ptr
            body_ ~= Op.global_get;
            leb128u(body_, heapPtrGlobal);
            body_ ~= Op.local_set;
            leb128u(body_, 1);  // local 1 = result
            
            // heap_ptr = heap_ptr + ((size + 7) & ~7)  // align to 8
            body_ ~= Op.global_get;
            leb128u(body_, heapPtrGlobal);
            
            // (size + 7) & ~7
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // size
            body_ ~= Op.i32_const;
            leb128s(body_, 7);
            body_ ~= Op.i32_add;
            body_ ~= Op.i32_const;
            leb128s(body_, ~7);
            body_ ~= Op.i32_and;
            
            body_ ~= Op.i32_add;
            body_ ~= Op.global_set;
            leb128u(body_, heapPtrGlobal);
            
            // return result
            body_ ~= Op.local_get;
            leb128u(body_, 1);
            body_ ~= Op.end;
            
        } else if (f.name == "__array_concat") {
            // $string_concat(s1: i32, s2: i32) -> i32
            // s1, s2 are pointers to Array structs
            //
            // Array struct: { ptr: i32, len: i32, cap: i32 }
            //
            // new_len = s1.len + s2.len
            // buffer = alloc(new_len)
            // result = alloc(12)  // Array struct
            // memory.copy(buffer, s1.ptr, s1.len)
            // memory.copy(buffer + s1.len, s2.ptr, s2.len)
            // result.ptr = buffer
            // result.len = new_len
            // result.cap = new_len
            // return result
            
            // Locals:
            // 0 = s1 (param)
            // 1 = s2 (param)
            // 2 = s1_ptr
            // 3 = s1_len
            // 4 = s2_ptr
            // 5 = s2_len
            // 6 = new_len
            // 7 = buffer
            // 8 = result
            
            leb128u(body_, 1);  // 1 local group
            leb128u(body_, 7);  // 7 locals (indices 2-8)
            body_ ~= cast(ubyte)ValType.i32;
            
            // Load s1.ptr and s1.len
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // s1
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, sliceInfo.ptrOffset);
            body_ ~= Op.local_set;
            leb128u(body_, 2);  // s1_ptr
            
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // s1
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, sliceInfo.lengthOffset);
            body_ ~= Op.local_set;
            leb128u(body_, 3);  // s1_len
            
            // Load s2.ptr and s2.len
            body_ ~= Op.local_get;
            leb128u(body_, 1);  // s2
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, sliceInfo.ptrOffset);
            body_ ~= Op.local_set;
            leb128u(body_, 4);  // s2_ptr
            
            body_ ~= Op.local_get;
            leb128u(body_, 1);  // s2
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, sliceInfo.lengthOffset);
            body_ ~= Op.local_set;
            leb128u(body_, 5);  // s2_len
            
            // new_len = s1_len + s2_len
            body_ ~= Op.local_get;
            leb128u(body_, 3);
            body_ ~= Op.local_get;
            leb128u(body_, 5);
            body_ ~= Op.i32_add;
            body_ ~= Op.local_set;
            leb128u(body_, 6);  // new_len
            
            // buffer = arena_alloc(arena_base, new_len)
            body_ ~= Op.global_get;
            leb128u(body_, arenaBaseGlobal);
            body_ ~= Op.local_get;
            leb128u(body_, 6);
            body_ ~= Op.call;
            leb128u(body_, arenaAllocFuncIndex);
            body_ ~= Op.local_set;
            leb128u(body_, 7);  // buffer

            // result = arena_alloc(arena_base, 12)  // Array struct size
            body_ ~= Op.global_get;
            leb128u(body_, arenaBaseGlobal);
            body_ ~= Op.i32_const;
            leb128s(body_, sliceInfo.totalSize);
            body_ ~= Op.call;
            leb128u(body_, arenaAllocFuncIndex);
            body_ ~= Op.local_set;
            leb128u(body_, 8);  // result
            
            // memory.copy(buffer, s1_ptr, s1_len)
            body_ ~= Op.local_get;
            leb128u(body_, 7);  // dest = buffer
            body_ ~= Op.local_get;
            leb128u(body_, 2);  // src = s1_ptr
            body_ ~= Op.local_get;
            leb128u(body_, 3);  // len = s1_len
            body_ ~= cast(ubyte)0xFC;  // memory.copy prefix
            body_ ~= cast(ubyte)0x0A;  // memory.copy opcode
            leb128u(body_, 0);  // dest memory
            leb128u(body_, 0);  // src memory
            
            // memory.copy(buffer + s1_len, s2_ptr, s2_len)
            body_ ~= Op.local_get;
            leb128u(body_, 7);  // buffer
            body_ ~= Op.local_get;
            leb128u(body_, 3);  // s1_len
            body_ ~= Op.i32_add;  // dest = buffer + s1_len
            body_ ~= Op.local_get;
            leb128u(body_, 4);  // src = s2_ptr
            body_ ~= Op.local_get;
            leb128u(body_, 5);  // len = s2_len
            body_ ~= cast(ubyte)0xFC;
            body_ ~= cast(ubyte)0x0A;
            leb128u(body_, 0);
            leb128u(body_, 0);
            
            // result.ptr = buffer
            body_ ~= Op.local_get;
            leb128u(body_, 8);  // result
            body_ ~= Op.local_get;
            leb128u(body_, 7);  // buffer
            body_ ~= Op.i32_store;
            leb128u(body_, 2);  // align
            leb128u(body_, sliceInfo.ptrOffset);
            
            // result.len = new_len
            body_ ~= Op.local_get;
            leb128u(body_, 8);  // result
            body_ ~= Op.local_get;
            leb128u(body_, 6);  // new_len
            body_ ~= Op.i32_store;
            leb128u(body_, 2);  // align
            leb128u(body_, sliceInfo.lengthOffset);
            
            // result.cap = new_len
            body_ ~= Op.local_get;
            leb128u(body_, 8);  // result
            body_ ~= Op.local_get;
            leb128u(body_, 6);  // new_len
            body_ ~= Op.i32_store;
            leb128u(body_, 2);  // align
            leb128u(body_, sliceInfo.capacityOffset);
            
            // return result
            body_ ~= Op.local_get;
            leb128u(body_, 8);
            body_ ~= Op.end;
            
        } else if (f.name == "__arena_alloc") {
            import codegen.wasm.types : ARENA_OFFSET_FIELD, ARENA_END_FIELD, MEMORY_ALIGNMENT;
            // __arena_alloc(arena: i32, size: i32) -> i32
            // Bump allocator with automatic memory growth.
            //
            // local 0 = arena (param, pointer to ArenaHeader)
            // local 1 = size (param)
            // local 2 = result (aligned current offset)
            // local 3 = new_end (result + size)
            //
            // result = (arena.offset + 7) & ~7
            // new_end = result + size
            // if new_end > arena.end:
            //     pages = (new_end - arena.end + 65535) >> 16
            //     if memory.grow(pages) == -1: unreachable
            //     arena.end = memory.size * 65536
            // arena.offset = new_end
            // return result

            leb128u(body_, 1);  // 1 local group
            leb128u(body_, 2);  // 2 locals
            body_ ~= cast(ubyte)ValType.i32;

            // result = (arena.offset + 7) & ~7
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // arena
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, ARENA_OFFSET_FIELD);
            body_ ~= Op.i32_const;
            leb128s(body_, cast(int)(MEMORY_ALIGNMENT - 1));
            body_ ~= Op.i32_add;
            body_ ~= Op.i32_const;
            leb128s(body_, cast(int)(~(MEMORY_ALIGNMENT - 1)));
            body_ ~= Op.i32_and;
            body_ ~= Op.local_set;
            leb128u(body_, 2);  // result

            // new_end = result + size
            body_ ~= Op.local_get;
            leb128u(body_, 2);  // result
            body_ ~= Op.local_get;
            leb128u(body_, 1);  // size
            body_ ~= Op.i32_add;
            body_ ~= Op.local_set;
            leb128u(body_, 3);  // new_end

            // if new_end > arena.end:
            body_ ~= Op.local_get;
            leb128u(body_, 3);  // new_end
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // arena
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, ARENA_END_FIELD);
            body_ ~= Op.i32_gt_u;
            body_ ~= Op.if_;
            body_ ~= cast(ubyte)0x40;  // void block

                // pages = (new_end - arena.end + 65535) >> 16
                body_ ~= Op.local_get;
                leb128u(body_, 3);  // new_end
                body_ ~= Op.local_get;
                leb128u(body_, 0);  // arena
                body_ ~= Op.i32_load;
                leb128u(body_, 2);  // align
                leb128u(body_, ARENA_END_FIELD);
                body_ ~= Op.i32_sub;  // overshoot
                body_ ~= Op.i32_const;
                leb128s(body_, 65535);
                body_ ~= Op.i32_add;  // overshoot + 65535
                body_ ~= Op.i32_const;
                leb128s(body_, 16);
                body_ ~= Op.i32_shr_u;  // pages = ceil div 65536

                // if memory.grow(pages) == -1: unreachable
                body_ ~= Op.memory_grow;
                body_ ~= cast(ubyte)0x00;  // memory index 0
                body_ ~= Op.i32_const;
                leb128s(body_, -1);
                body_ ~= Op.i32_eq;
                body_ ~= Op.if_;
                body_ ~= cast(ubyte)0x40;  // void block
                    body_ ~= Op.unreachable;
                body_ ~= Op.end;  // end OOM check

                // arena.end = memory.size * 65536
                body_ ~= Op.local_get;
                leb128u(body_, 0);  // arena
                body_ ~= Op.memory_size;
                body_ ~= cast(ubyte)0x00;  // memory index 0
                body_ ~= Op.i32_const;
                leb128s(body_, 16);
                body_ ~= Op.i32_shl;  // memory.size * 65536
                body_ ~= Op.i32_store;
                leb128u(body_, 2);  // align
                leb128u(body_, ARENA_END_FIELD);

            body_ ~= Op.end;  // end growth check

            // arena.offset = new_end
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // arena
            body_ ~= Op.local_get;
            leb128u(body_, 3);  // new_end
            body_ ~= Op.i32_store;
            leb128u(body_, 2);  // align
            leb128u(body_, ARENA_OFFSET_FIELD);

            // return result
            body_ ~= Op.local_get;
            leb128u(body_, 2);
            body_ ~= Op.end;

        } else if (f.name == "__arena_new") {
            import codegen.wasm.types : ARENA_OFFSET_FIELD, ARENA_SAVE_COUNT_FIELD,
                                        ARENA_HEADER_SIZE;
            // __arena_new(arena: i32) -> void
            // Push current arena.offset onto the watermark stack.
            //
            // local 0 = arena (param)
            // local 1 = wm_top (current watermark stack index)
            //
            // wm_top = global.__arena_wm_top
            // watermark_stack[wm_top] = arena.offset
            // global.__arena_wm_top = wm_top + 1
            // arena.save_count += 1

            leb128u(body_, 1);  // 1 local group
            leb128u(body_, 1);  // 1 local
            body_ ~= cast(ubyte)ValType.i32;

            // wm_top = global.__arena_wm_top
            body_ ~= Op.global_get;
            leb128u(body_, arenaWatermarkGlobal);
            body_ ~= Op.local_set;
            leb128u(body_, 1);

            // Store arena.offset at watermark_stack[wm_top]
            // Address = arena_base + ARENA_HEADER_SIZE + wm_top * 4
            body_ ~= Op.global_get;
            leb128u(body_, arenaBaseGlobal);
            body_ ~= Op.i32_const;
            leb128s(body_, ARENA_HEADER_SIZE);
            body_ ~= Op.i32_add;
            body_ ~= Op.local_get;
            leb128u(body_, 1);  // wm_top
            body_ ~= Op.i32_const;
            leb128s(body_, 4);
            body_ ~= Op.i32_mul;
            body_ ~= Op.i32_add;
            // Now stack has the destination address
            // Load arena.offset
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // arena
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, ARENA_OFFSET_FIELD);
            // Store
            body_ ~= Op.i32_store;
            leb128u(body_, 2);  // align
            leb128u(body_, 0);  // offset 0

            // global.__arena_wm_top = wm_top + 1
            body_ ~= Op.local_get;
            leb128u(body_, 1);
            body_ ~= Op.i32_const;
            leb128s(body_, 1);
            body_ ~= Op.i32_add;
            body_ ~= Op.global_set;
            leb128u(body_, arenaWatermarkGlobal);

            // arena.save_count += 1
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // arena
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // arena
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, ARENA_SAVE_COUNT_FIELD);
            body_ ~= Op.i32_const;
            leb128s(body_, 1);
            body_ ~= Op.i32_add;
            body_ ~= Op.i32_store;
            leb128u(body_, 2);  // align
            leb128u(body_, ARENA_SAVE_COUNT_FIELD);

            body_ ~= Op.end;

        } else if (f.name == "__arena_drop") {
            import codegen.wasm.types : ARENA_OFFSET_FIELD, ARENA_SAVE_COUNT_FIELD,
                                        ARENA_HEADER_SIZE;
            // __arena_drop(arena: i32) -> void
            // Pop watermark stack, restore arena.offset.
            //
            // local 0 = arena (param)
            // local 1 = wm_top (new top after decrement)
            //
            // wm_top = global.__arena_wm_top - 1
            // global.__arena_wm_top = wm_top
            // arena.offset = watermark_stack[wm_top]
            // arena.save_count -= 1

            leb128u(body_, 1);  // 1 local group
            leb128u(body_, 1);  // 1 local
            body_ ~= cast(ubyte)ValType.i32;

            // wm_top = global.__arena_wm_top - 1
            body_ ~= Op.global_get;
            leb128u(body_, arenaWatermarkGlobal);
            body_ ~= Op.i32_const;
            leb128s(body_, 1);
            body_ ~= Op.i32_sub;
            body_ ~= Op.local_tee;
            leb128u(body_, 1);
            // Also update global
            body_ ~= Op.global_set;
            leb128u(body_, arenaWatermarkGlobal);

            // arena.offset = watermark_stack[wm_top]
            // Load from: arena_base + ARENA_HEADER_SIZE + wm_top * 4
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // arena (destination for store)
            body_ ~= Op.global_get;
            leb128u(body_, arenaBaseGlobal);
            body_ ~= Op.i32_const;
            leb128s(body_, ARENA_HEADER_SIZE);
            body_ ~= Op.i32_add;
            body_ ~= Op.local_get;
            leb128u(body_, 1);  // wm_top
            body_ ~= Op.i32_const;
            leb128s(body_, 4);
            body_ ~= Op.i32_mul;
            body_ ~= Op.i32_add;
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, 0);  // offset 0
            // Store to arena.offset
            body_ ~= Op.i32_store;
            leb128u(body_, 2);  // align
            leb128u(body_, ARENA_OFFSET_FIELD);

            // arena.save_count -= 1
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // arena
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // arena
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, ARENA_SAVE_COUNT_FIELD);
            body_ ~= Op.i32_const;
            leb128s(body_, 1);
            body_ ~= Op.i32_sub;
            body_ ~= Op.i32_store;
            leb128u(body_, 2);  // align
            leb128u(body_, ARENA_SAVE_COUNT_FIELD);

            body_ ~= Op.end;

        } else if (f.name == "__eval") {
            // __eval() -> i32/f64
            // Evaluates the stored expression and returns the result
            
            leb128u(body_, 0);  // No locals
            
            // Create a context to emit the expression
            auto ctx = new EvalContext(this);
            ctx.emitExpression(body_, evalExpression);
            
            body_ ~= Op.end;
            
        } else {
            throw new EmitError("Unknown built-in function: " ~ f.name, SourceLocation.init);
        }
        
        return body_.data;
    }
    
    //==========================================================================
    // Data Section
    //==========================================================================
    
    private void emitDataSection() {
        if (dataEntries.length == 0) return;

        // Convert to section builder's DataEntry format
        import codegen.wasm.sections.data : DataEntry_ = DataEntry;
        auto sectionEntries = dataEntries.map!(e => DataEntry_(e.offset, e.data)).array;

        if (auto content = buildDataSection(sectionEntries))
            emitSection(Section.data, content);
    }

    /**
     * Emit a custom "ffi_meta" section describing extern(C) FFI imports.
     * Format:
     *   section_id: 0 (custom)
     *   name: "ffi_meta" (LEB128 length-prefixed)
     *   body:
     *     count: LEB128 u32
     *     per entry:
     *       name_len: LEB128 u32
     *       name_bytes: UTF-8
     *       ret_kind: u8
     *       param_count: u8
     *       param_kinds: u8[param_count]
     */
    private void emitFFIMetaSection() {
        Appender!(ubyte[]) body_;

        // Section name "ffi_meta"
        enum sectionName = "ffi_meta";
        leb128u(body_, sectionName.length);
        body_ ~= cast(const(ubyte)[])sectionName;

        // Number of FFI imports
        leb128u(body_, ffiMetas.length);

        foreach (ref meta; ffiMetas) {
            // Function name
            leb128u(body_, meta.name.length);
            body_ ~= cast(const(ubyte)[])meta.name;

            // Return kind
            body_ ~= cast(ubyte)meta.retKind;

            // Struct return metadata (when retKind == RET_STRUCT)
            if (meta.retKind == ArgKind.RET_STRUCT) {
                leb128u(body_, meta.retStructSize);
                body_ ~= cast(ubyte)meta.retStructFieldKinds.length;
                foreach (fk; meta.retStructFieldKinds)
                    body_ ~= cast(ubyte)fk;
            }

            // Parameter count and kinds
            body_ ~= cast(ubyte)meta.paramKinds.length;
            foreach (k; meta.paramKinds) {
                body_ ~= cast(ubyte)k;
            }

            // Optional native name alias (for objc_msgSend dispatch)
            if (meta.nativeName.length > 0) {
                body_ ~= cast(ubyte)1;
                leb128u(body_, meta.nativeName.length);
                body_ ~= cast(const(ubyte)[])meta.nativeName;
            } else {
                body_ ~= cast(ubyte)0;
            }
        }

        emitSection(Section.custom, body_.data);
    }

    /**
     * Emit a custom "objc_classes" section describing extern(Objective-C) class definitions.
     * Format:
     *   section_id: 0 (custom)
     *   name: "objc_classes" (LEB128 length-prefixed)
     *   body:
     *     count: LEB128 u32
     *     per class:
     *       class_name_len: LEB128 u32, class_name: bytes
     *       super_name_len: LEB128 u32, super_name: bytes
     *       method_count: LEB128 u32
     *       per method:
     *         selector_len: LEB128 u32, selector: bytes
     *         wasm_export_len: LEB128 u32, wasm_export: bytes
     *         type_encoding_len: LEB128 u32, type_encoding: bytes
     *         ret_kind: u8
     *         param_count: u8, param_kinds: u8[]  (user args only, no self/_cmd)
     */
    private void emitObjCClassesSection() {
        Appender!(ubyte[]) body_;

        enum sectionName = "objc_classes";
        leb128u(body_, sectionName.length);
        body_ ~= cast(const(ubyte)[])sectionName;

        // Number of classes
        leb128u(body_, objcClassMetas.length);

        foreach (ref cls; objcClassMetas) {
            // Class name
            leb128u(body_, cls.className.length);
            body_ ~= cast(const(ubyte)[])cls.className;

            // Superclass name
            leb128u(body_, cls.superName.length);
            body_ ~= cast(const(ubyte)[])cls.superName;

            // Method count
            leb128u(body_, cls.methods.length);

            foreach (ref m; cls.methods) {
                // Selector
                leb128u(body_, m.selector.length);
                body_ ~= cast(const(ubyte)[])m.selector;

                // WASM export name
                leb128u(body_, m.wasmExport.length);
                body_ ~= cast(const(ubyte)[])m.wasmExport;

                // ObjC type encoding
                leb128u(body_, m.typeEncoding.length);
                body_ ~= cast(const(ubyte)[])m.typeEncoding;

                // Return kind
                body_ ~= cast(ubyte)m.retKind;

                // Param count + kinds (user args only)
                body_ ~= cast(ubyte)m.paramKinds.length;
                foreach (k; m.paramKinds) {
                    body_ ~= cast(ubyte)k;
                }
            }
        }

        emitSection(Section.custom, body_.data);
    }

    /**
     * Add a data entry (string literal, etc.)
     * Returns the memory offset
     */
    package uint addData(ubyte[] data) {
        uint offset = nextDataOffset;
        dataEntries ~= DataEntry(offset, data.dup);
        nextDataOffset += cast(uint)data.length;
        // Align to 4 bytes
        nextDataOffset = (nextDataOffset + 3) & ~3;
        return offset;
    }
    
    /**
     * Get function index by name
     * 
     * In WASM, function indices are:
     *   0..N-1: imported functions
     *   N..:    local functions
     */
    /// Get the initial value of the arena base global (for CTFE callers to prepend).
    /// Returns 0 if arena builtins are not initialized.
    package uint getArenaBaseValue() {
        if (!hasArenaBuiltins) return 0;
        return cast(uint)globals[arenaBaseGlobal].initValue;
    }

    /// Get the memory offset of the pre-allocated exception slot array.
    uint getExceptionArrayOffset() {
        return exceptionArrayOffset;
    }

    package uint getFuncIndex(string name, SourceLocation loc = SourceLocation.init) {
        // Check if it's an imported function
        if (auto idx = name in importIndex) {
            return *idx;  // Import indices start at 0
        }

        // Check if it's a local function
        if (auto idx = name in funcIndex) {
            // Local function index + number of imports
            return cast(uint)imports.length + *idx;
        }

        if (name.length == 0)
            throw new EmitError("getFuncIndex called with empty function name (method not collected — missing parent declaration?)", loc);
        throw new EmitError("Unknown function: '" ~ name ~ "' — function was not collected by the emitter. "
            ~ "Possible causes: void function with no return value, missing from dependency analysis, "
            ~ "or unsupported calling pattern.", loc);
    }
    
    /**
     * Register a string literal and get its struct address.
     * Creates both the character data and the Array struct in the data section.
     */
    package uint registerArrayLiteral(string s) {
        // Check if we already have this string
        if (auto existing = s in arrayLiterals) {
            return existing.structOffset;
        }
        
        needsArraySupport = true;
        
        // Add the character data
        uint dataOffset = addData(cast(ubyte[])s);
        uint len = cast(uint)s.length;
        
        // Create the Array struct: { ptr, len, cap }
        ubyte[] structData = new ubyte[sliceInfo.totalSize];
        // Little-endian i32 values
        *cast(uint*)&structData[sliceInfo.ptrOffset] = dataOffset;
        *cast(uint*)&structData[sliceInfo.lengthOffset] = len;
        *cast(uint*)&structData[sliceInfo.capacityOffset] = len;

        uint structOffset = addData(structData);
        
        arrayLiterals[s] = ArrayLiteralInfo(structOffset, dataOffset, len);
        
        return structOffset;
    }
    
    /**
     * Register a manifest constant array (from import() or array literal CTFE)
     * and return the struct address in the data section.
     */
    package uint registerManifestArray(ManifestConstantDecl manifest) {
        // Check if already registered
        if (manifest.name in manifestArrayAddrs) {
            return manifestArrayAddrs[manifest.name];
        }
        
        needsArraySupport = true;
        
        // Add the raw bytes to data section
        uint dataOffset = addData(manifest.ctfeArrayBytes);
        uint byteLen = cast(uint)manifest.ctfeArrayBytes.length;
        // Element count, not byte count (for strings elementSize=1 so they're equal)
        uint elementCount = manifest.ctfeElementSize > 0
            ? byteLen / manifest.ctfeElementSize
            : byteLen;

        // Create the Array struct: { ptr, len, cap }
        ubyte[] structData = new ubyte[sliceInfo.totalSize];
        *cast(uint*)&structData[sliceInfo.ptrOffset] = dataOffset;
        *cast(uint*)&structData[sliceInfo.lengthOffset] = elementCount;
        *cast(uint*)&structData[sliceInfo.capacityOffset] = elementCount;

        uint structOffset = addData(structData);
        manifestArrayAddrs[manifest.name] = structOffset;
        
        return structOffset;
    }
    
    /**
     * Register a nested array manifest (T[][]) in the data section.
     * Builds a two-level layout: inner data blobs, inner slice structs, outer slice struct.
     * Returns the address of the outer slice struct.
     */
    package uint registerManifestNestedArray(ManifestConstantDecl manifest) {
        // Check if already registered
        if (manifest.name in manifestArrayAddrs) {
            return manifestArrayAddrs[manifest.name];
        }

        needsArraySupport = true;

        uint outerCount = cast(uint)manifest.ctfeNestedElements.length;
        uint innerElemSize = manifest.ctfeInnerElementSize;

        // 1. Add each inner array's raw data to the data section
        uint[] innerDataOffsets = new uint[outerCount];
        uint[] innerLengths = new uint[outerCount];
        foreach (i; 0 .. outerCount) {
            ubyte[] innerBytes = manifest.ctfeNestedElements[i];
            innerDataOffsets[i] = addData(innerBytes);
            innerLengths[i] = innerElemSize > 0
                ? cast(uint)innerBytes.length / innerElemSize
                : cast(uint)innerBytes.length;
        }

        // 2. Build the array of inner slice structs
        ubyte[] innerStructsData = new ubyte[outerCount * sliceInfo.totalSize];
        foreach (i; 0 .. outerCount) {
            uint base = i * sliceInfo.totalSize;
            *cast(uint*)&innerStructsData[base + sliceInfo.ptrOffset] = innerDataOffsets[i];
            *cast(uint*)&innerStructsData[base + sliceInfo.lengthOffset] = innerLengths[i];
            *cast(uint*)&innerStructsData[base + sliceInfo.capacityOffset] = innerLengths[i];
        }
        uint innerStructsOffset = addData(innerStructsData);

        // 3. Build the outer slice struct pointing to the inner structs array
        ubyte[] outerStruct = new ubyte[sliceInfo.totalSize];
        *cast(uint*)&outerStruct[sliceInfo.ptrOffset] = innerStructsOffset;
        *cast(uint*)&outerStruct[sliceInfo.lengthOffset] = outerCount;
        *cast(uint*)&outerStruct[sliceInfo.capacityOffset] = outerCount;

        uint outerOffset = addData(outerStruct);
        manifestArrayAddrs[manifest.name] = outerOffset;

        return outerOffset;
    }

    /**
     * Check if array support is needed (exposes for CTFE)
     */
    bool hasStringSupport() const {
        return needsArraySupport;
    }
    
    /**
     * Register a struct literal and get its address in the data section.
     * The struct fields are stored contiguously.
     */
    uint registerStructLiteral(StructDecl structDecl, int[] fieldValues) {
        // Build the struct data based on field layout
        ubyte[] structData = new ubyte[structDecl.structSize];
        
        for (size_t i = 0; i < structDecl.fields.length && i < fieldValues.length; i++) {
            auto field = structDecl.fields[i];
            // For now, assume all fields are i32
            *cast(int*)&structData[field.offset] = fieldValues[i];
        }
        
        return addData(structData);
        }
}

//==============================================================================
// Eval Context - For expression evaluation in __eval (no locals, no params)
//==============================================================================

private class EvalContext {
    BinaryEmitter emitter;
    
    this(BinaryEmitter e) {
        this.emitter = e;
    }
    
    void emitExpression(ref Appender!(ubyte[]) out_, Expression expr) {
        if (auto literal = cast(LiteralExpression)expr) {
            emitLiteral(out_, literal);
        } else if (auto ident = cast(IdentifierExpression)expr) {
            emitIdentifier(out_, ident);
        } else if (auto unary = cast(UnaryExpression)expr) {
            emitUnary(out_, unary);
        } else if (auto binary = cast(BinaryExpression)expr) {
            emitBinary(out_, binary);
        } else if (auto call = cast(CallExpression)expr) {
            emitCallExpr(out_, call);
        } else {
            throw new EmitError("Unsupported expression in __eval: " ~ expr.toString(), expr.location);
        }
    }

    void emitUnary(ref Appender!(ubyte[]) out_, UnaryExpression expr) {
        if (expr.operator == UnaryExpression.Operator.Minus) {
            if (isFloatExpr(expr.operand)) {
                // f64 negation
                emitExpression(out_, expr.operand);
                out_ ~= Op.f64_neg;
            } else {
                // -x => 0 - x
                out_ ~= Op.i32_const;
                leb128s(out_, 0);
                emitExpression(out_, expr.operand);
                out_ ~= Op.i32_sub;
            }
        } else if (expr.operator == UnaryExpression.Operator.BitwiseNot) {
            // ~x => x ^ -1
            emitExpression(out_, expr.operand);
            out_ ~= Op.i32_const;
            leb128s(out_, -1);
            out_ ~= Op.i32_xor;
        } else if (expr.operator == UnaryExpression.Operator.LogicalNot) {
            // !x => x == 0
            emitExpression(out_, expr.operand);
            out_ ~= Op.i32_eqz;
        } else {
            throw new EmitError("Unsupported unary operator in __eval", expr.location);
        }
    }
    
    void emitCallExpr(ref Appender!(ubyte[]) out_, CallExpression expr) {
        auto ident = cast(IdentifierExpression)expr.function_;
        if (!ident) {
            throw new EmitError("Unsupported call expression in __eval", expr.location);
        }
        
        // Compiler intrinsics — raw opcodes
        if (ident.name.length > 12 && ident.name[0..12] == "__intrinsic_") {
            foreach (arg; expr.arguments)
                emitExpression(out_, arg);
            if (ident.name == "__intrinsic_shl")
                out_ ~= Op.i32_shl;
            else if (ident.name == "__intrinsic_shr_s")
                out_ ~= Op.i32_shr_s;
            else if (ident.name == "__intrinsic_shr_u")
                out_ ~= Op.i32_shr_u;
            else if (ident.name == "__intrinsic_shl_i64")
                out_ ~= Op.i64_shl;
            else if (ident.name == "__intrinsic_shr_s_i64")
                out_ ~= Op.i64_shr_s;
            else if (ident.name == "__intrinsic_shr_u_i64")
                out_ ~= Op.i64_shr_u;
            else if (ident.name == "__intrinsic_unreachable")
                out_ ~= Op.unreachable;
            else
                throw new EmitError("Unknown intrinsic in __eval: " ~ ident.name, expr.location);
            return;
        }

        if (ident.name == "__text") {
            // __text(expr) - convert integer expression to string at compile time
            if (expr.arguments.length != 1) {
                throw new EmitError("__text requires exactly one argument", expr.location);
            }
            
            // Evaluate the argument to get an integer value
            long value = evaluateIntExpr(expr.arguments[0]);
            
            // Convert to string
            string strValue = to!string(value);
            
            // Register as a string literal and emit pointer
            uint structAddr = emitter.registerArrayLiteral(strValue);
            out_ ~= Op.i32_const;
            leb128s(out_, structAddr);
        } else {
            throw new EmitError("Unknown intrinsic in __eval: " ~ ident.name, expr.location);
        }
    }
    
    /**
     * Evaluate an integer expression at compile time (for __text argument)
     */
    long evaluateIntExpr(Expression expr) {
        if (auto literal = cast(LiteralExpression)expr) {
            if (literal.value.type == typeid(long)) {
                return literal.value.get!long();
            }
            throw new EmitError("Expected integer in __text argument", expr.location);
        }
        
        if (auto ident = cast(IdentifierExpression)expr) {
            auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.isConstant) {
                if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                    if (!manifest.isStringType) {
                        manifest.ensureEvaluated();
                        return manifest.ctfeValue;
                    }
                }
            }
            throw new EmitError("Unknown or non-integer identifier in __text: " ~ ident.name, expr.location);
        }
        
        if (auto binary = cast(BinaryExpression)expr) {
            long left = evaluateIntExpr(binary.left);
            long right = evaluateIntExpr(binary.right);
            
            final switch (binary.operator) {
                case BinaryExpression.Operator.Add: return left + right;
                case BinaryExpression.Operator.Subtract: return left - right;
                case BinaryExpression.Operator.Multiply: return left * right;
                case BinaryExpression.Operator.Divide: return left / right;
                case BinaryExpression.Operator.Modulo: return left % right;
                case BinaryExpression.Operator.Equal: return left == right ? 1 : 0;
                case BinaryExpression.Operator.NotEqual: return left != right ? 1 : 0;
                case BinaryExpression.Operator.Less: return left < right ? 1 : 0;
                case BinaryExpression.Operator.LessEqual: return left <= right ? 1 : 0;
                case BinaryExpression.Operator.Greater: return left > right ? 1 : 0;
                case BinaryExpression.Operator.GreaterEqual: return left >= right ? 1 : 0;
                case BinaryExpression.Operator.LogicalAnd: return (left != 0 && right != 0) ? 1 : 0;
                case BinaryExpression.Operator.LogicalOr: return (left != 0 || right != 0) ? 1 : 0;
                case BinaryExpression.Operator.BitwiseAnd: return left & right;
                case BinaryExpression.Operator.BitwiseOr: return left | right;
                case BinaryExpression.Operator.BitwiseXor: return left ^ right;
                case BinaryExpression.Operator.ShiftLeft: return left << right;
                case BinaryExpression.Operator.ShiftRight: return left >> right;
                case BinaryExpression.Operator.UnsignedShiftRight: return left >>> right;
                case BinaryExpression.Operator.Concat: 
                    throw new EmitError("Concat not supported in __text argument", expr.location);
            }
        }
        
        throw new EmitError("Cannot evaluate __text argument", expr.location);
    }
    
    void emitLiteral(ref Appender!(ubyte[]) out_, LiteralExpression expr) {
        if (expr.value.type == typeid(string)) {
            // String literal: emit pointer to Array struct
            string s = expr.value.get!string();
            uint structAddr = emitter.registerArrayLiteral(s);
            out_ ~= Op.i32_const;
            leb128s(out_, structAddr);
        } else if (expr.value.type == typeid(double)) {
            out_ ~= Op.f64_const;
            double val = expr.value.get!double();
            out_ ~= (cast(ubyte*)&val)[0 .. 8];
        } else if (expr.value.type == typeid(long)) {
            out_ ~= Op.i32_const;
            leb128s(out_, expr.value.get!long());
        } else {
            throw new EmitError("Unsupported literal type in __eval", expr.location);
        }
    }
    
    void emitIdentifier(ref Appender!(ubyte[]) out_, IdentifierExpression expr) {
        // Must be a manifest constant - evaluate lazily
        auto symbol = emitter.symbolTable.lookupSymbol(expr.name);
        if (symbol && symbol.isConstant) {
            if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                assert(manifest.ownModuleResolver !is null,
                    "Manifest '" ~ manifest.name ~ "' reached codegen without resolver stamp");
                manifest.ensureEvaluated();
                if (manifest.isStringType) {
                    uint structAddr = emitter.registerArrayLiteral(manifest.ctfeStringValue);
                    out_ ~= Op.i32_const;
                    leb128s(out_, structAddr);
                } else if (manifest.isFloatType) {
                    out_ ~= Op.f64_const;
                    double val = manifest.ctfeFloatValue;
                    out_ ~= (cast(ubyte*)&val)[0 .. 8];
                } else {
                    out_ ~= Op.i32_const;
                    leb128s(out_, manifest.ctfeValue);
                }
                return;
            }
        }
        throw new EmitError("Unknown identifier in __eval: " ~ expr.name, expr.location);
    }
    
    void emitBinary(ref Appender!(ubyte[]) out_, BinaryExpression expr) {
        if (expr.operator == BinaryExpression.Operator.Concat) {
            emitArrayConcat(out_, expr);
            return;
        }
        // Lowered operators (shifts, struct comparison) — emit the lowered expression
        if (expr.loweredCall) {
            emitExpression(out_, expr.loweredCall);
            return;
        }
        // LogicalAnd/LogicalOr need boolean normalization (eqz+eqz converts to 0/1)
        if (expr.operator == BinaryExpression.Operator.LogicalAnd) {
            emitExpression(out_, expr.left);
            out_ ~= Op.i32_eqz;
            out_ ~= Op.i32_eqz;
            emitExpression(out_, expr.right);
            out_ ~= Op.i32_eqz;
            out_ ~= Op.i32_eqz;
            out_ ~= Op.i32_and;
            return;
        }
        if (expr.operator == BinaryExpression.Operator.LogicalOr) {
            emitExpression(out_, expr.left);
            out_ ~= Op.i32_eqz;
            out_ ~= Op.i32_eqz;
            emitExpression(out_, expr.right);
            out_ ~= Op.i32_eqz;
            out_ ~= Op.i32_eqz;
            out_ ~= Op.i32_or;
            return;
        }
        // Arithmetic/comparison — emit both operands then the operator
        emitExpression(out_, expr.left);
        emitExpression(out_, expr.right);
        if (isFloatExpr(expr.left) || isFloatExpr(expr.right)) {
            // Float arithmetic/comparison
            final switch (expr.operator) {
                case BinaryExpression.Operator.Add: out_ ~= Op.f64_add; break;
                case BinaryExpression.Operator.Subtract: out_ ~= Op.f64_sub; break;
                case BinaryExpression.Operator.Multiply: out_ ~= Op.f64_mul; break;
                case BinaryExpression.Operator.Divide: out_ ~= Op.f64_div; break;
                case BinaryExpression.Operator.Modulo:
                    throw new EmitError("Modulo not supported for float in __eval", expr.location);
                case BinaryExpression.Operator.Equal: out_ ~= Op.f64_eq; break;
                case BinaryExpression.Operator.NotEqual: out_ ~= Op.f64_ne; break;
                case BinaryExpression.Operator.Less: out_ ~= Op.f64_lt; break;
                case BinaryExpression.Operator.LessEqual: out_ ~= Op.f64_le; break;
                case BinaryExpression.Operator.Greater: out_ ~= Op.f64_gt; break;
                case BinaryExpression.Operator.GreaterEqual: out_ ~= Op.f64_ge; break;
                case BinaryExpression.Operator.LogicalAnd: assert(0);
                case BinaryExpression.Operator.LogicalOr: assert(0);
                case BinaryExpression.Operator.BitwiseAnd:
                case BinaryExpression.Operator.BitwiseOr:
                case BinaryExpression.Operator.BitwiseXor:
                    throw new EmitError("Bitwise ops not supported for float in __eval", expr.location);
                case BinaryExpression.Operator.ShiftLeft:
                case BinaryExpression.Operator.ShiftRight:
                case BinaryExpression.Operator.UnsignedShiftRight:
                    throw new EmitError("Shift ops not supported for float in __eval", expr.location);
                case BinaryExpression.Operator.Concat: assert(0);
            }
        } else {
            // Integer arithmetic/comparison
            final switch (expr.operator) {
                case BinaryExpression.Operator.Add: out_ ~= Op.i32_add; break;
                case BinaryExpression.Operator.Subtract: out_ ~= Op.i32_sub; break;
                case BinaryExpression.Operator.Multiply: out_ ~= Op.i32_mul; break;
                case BinaryExpression.Operator.Divide: out_ ~= Op.i32_div_s; break;
                case BinaryExpression.Operator.Modulo: out_ ~= Op.i32_rem_s; break;
                case BinaryExpression.Operator.Equal: out_ ~= Op.i32_eq; break;
                case BinaryExpression.Operator.NotEqual: out_ ~= Op.i32_ne; break;
                case BinaryExpression.Operator.Less: out_ ~= Op.i32_lt_s; break;
                case BinaryExpression.Operator.LessEqual: out_ ~= Op.i32_le_s; break;
                case BinaryExpression.Operator.Greater: out_ ~= Op.i32_gt_s; break;
                case BinaryExpression.Operator.GreaterEqual: out_ ~= Op.i32_ge_s; break;
                case BinaryExpression.Operator.LogicalAnd: assert(0);
                case BinaryExpression.Operator.LogicalOr: assert(0);
                case BinaryExpression.Operator.BitwiseAnd: out_ ~= Op.i32_and; break;
                case BinaryExpression.Operator.BitwiseOr: out_ ~= Op.i32_or; break;
                case BinaryExpression.Operator.BitwiseXor: out_ ~= Op.i32_xor; break;
                case BinaryExpression.Operator.ShiftLeft:
                    assert(0, "ShiftLeft should be lowered to opShiftLeft call");
                case BinaryExpression.Operator.ShiftRight:
                    assert(0, "ShiftRight should be lowered to opShiftRight call");
                case BinaryExpression.Operator.UnsignedShiftRight:
                    assert(0, "UnsignedShiftRight should be lowered to opUnsignedShiftRight call");
                case BinaryExpression.Operator.Concat: assert(0);
            }
        }
    }

    void emitArrayConcat(ref Appender!(ubyte[]) out_, BinaryExpression expr) {
        // Emit left operand (string pointer)
        emitExpression(out_, expr.left);

        // Emit right operand (string pointer)
        emitExpression(out_, expr.right);

        // Call __array_concat
        out_ ~= Op.call;
        leb128u(out_, emitter.concatFuncIndex);
    }

    /// Check if an expression produces a float value.
    private bool isFloatExpr(Expression expr) {
        if (auto literal = cast(LiteralExpression)expr) {
            return literal.value.type == typeid(double);
        }
        if (auto ident = cast(IdentifierExpression)expr) {
            auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.isConstant) {
                if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                    return manifest.isFloatType;
                }
            }
            return false;
        }
        if (auto unary = cast(UnaryExpression)expr) {
            return isFloatExpr(unary.operand);
        }
        if (auto binary = cast(BinaryExpression)expr) {
            return isFloatExpr(binary.left) || isFloatExpr(binary.right);
        }
        return false;
    }
}

//==============================================================================
// Unit Tests for Code Caching
//==============================================================================

unittest {
    import std.stdio : writeln;
    
    // Test source hash computation
    auto hash1 = BinaryEmitter.computeSourceHash("int foo() { return 42; }");
    auto hash2 = BinaryEmitter.computeSourceHash("int foo() { return 42; }");
    auto hash3 = BinaryEmitter.computeSourceHash("int foo() { return 43; }");
    
    assert(hash1 == hash2, "Same source should produce same hash");
    assert(hash1 != hash3, "Different source should produce different hash");
    
    writeln("✓ Source hash computation test passed");
}

unittest {
    import std.stdio : writeln;
    
    // Test CacheStats initialization
    auto emitter = new BinaryEmitter(null);
    auto stats = emitter.getCacheStats();
    
    assert(stats.totalFunctions == 0, "Initial totalFunctions should be 0");
    assert(stats.cacheHits == 0, "Initial cacheHits should be 0");
    assert(stats.cacheMisses == 0, "Initial cacheMisses should be 0");
    
    writeln("✓ CacheStats initialization test passed");
}
