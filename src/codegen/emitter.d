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
import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;
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
    string context;
    
    this(string msg, string context = null, string file = __FILE__, size_t line = __LINE__) {
        this.context = context;
        super(context ? format("%s (in %s)", msg, context) : msg, file, line);
    }
}

//==============================================================================
// Function Signature - imported from codegen.wasm.sections
//==============================================================================

//==============================================================================
// Collected Function Info
//==============================================================================

struct FuncInfo {
    string name;
    uint typeIndex;
    FunctionDecl decl;
    bool exported;
    bool isImport;
    StructDecl structParent;  // Non-null for methods
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
        bool enableStackTrace;  // Stack trace option (milestone 144)
    }
    
    private {
        // Output buffer
        Appender!(ubyte[]) output;
        
        // Type index mapping
        uint[FuncSig] typeIndex;
        
        // Built-in functions
        bool hasBuiltins = false;
        uint allocFuncIndex;
        
        // State
        EmitPhase phase = EmitPhase.init;
        string lastError;
        
        // Memory tracking
        bool needsMemory = false;
        uint memoryPages = 1;
        
        // Globals (heap_ptr, etc.)
        struct GlobalInfo {
            ValType type;
            bool mutable;
            long initValue;
            string name;
        }
        GlobalInfo[] globals;
        uint heapPtrGlobal;  // Index of $heap_ptr global
        bool needsShadowStack = false;  // Set when any function has struct locals
        
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
        stats.totalFunctions = functions.length;
        stats.cacheHits = cacheHits.length;
        stats.cacheMisses = stats.totalFunctions - stats.cacheHits;
        return stats;
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
    ubyte[] emit(Declaration[] decls) {
        try {
            phase = EmitPhase.collecting;
            collect(decls);
            
            // If string operations are needed, add built-ins
            if (needsArraySupport) {
                addArrayBuiltins();
                finalizeHeapPtr();  // Set heap_ptr to after data section
            }
            
            // Always add shadow stack for struct locals
            addShadowStackGlobal();
            
            // Add call stack tracking global if enabled
            if (enableStackTrace) {
                addCallStackGlobal();
            }
            
            // Add imports for CTFE-only functions that are called
            addCTFEImports();
            
            // Stabilize indices for incremental compilation
            stabilizeIndices();
            
            phase = EmitPhase.init;
            emitHeader();
            
            phase = EmitPhase.emittingTypes;
            emitTypeSection();
            
            // Import section must come before function section
            emitImportSection();
            
            phase = EmitPhase.emittingFunctions;
            emitFunctionSection();
            
            phase = EmitPhase.emittingMemory;
            emitMemorySection();
            
            // Emit globals section (for heap_ptr)
            emitGlobalSection();
            
            phase = EmitPhase.emittingExports;
            emitExportSection();
            
            phase = EmitPhase.emittingCode;
            emitCodeSection();
            
            phase = EmitPhase.emittingData;
            emitDataSection();
            
            phase = EmitPhase.done;
            return output.data.dup;
            
        } catch (EmitError e) {
            phase = EmitPhase.error;
            lastError = e.msg;
            return null;
        } catch (Exception e) {
            phase = EmitPhase.error;
            lastError = "Internal error: " ~ e.msg;
            return null;
        }
    }
    
    /**
     * Get last error message
     */
    string error() const {
        return lastError;
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
            
            // Collect array literals from the expression
            collectArrayLiterals(expr);
            
            // Add built-ins (__alloc, __array_concat)
            addArrayBuiltins();
            
            // Add the __eval function
            addEvalFunction(expr);
            
            // Finalize heap pointer
            finalizeHeapPtr();
            
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
                        // Lazy evaluation via resolver
                        return symbolTable.resolveManifestValue(manifest);
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
    private void addEvalFunction(Expression expr) {
        // Type: () -> i32
        FuncSig evalSig;
        evalSig.params = [];
        evalSig.results = [ValType.i32];
        
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
        // First pass: collect imported functions (they need to come first in indices)
        foreach (decl; decls) {
            if (auto importedFunc = cast(ImportedFunctionDecl)decl) {
                collectImportedFunction(importedFunc);
            }
        }
        
        // Second pass: collect local functions, global variables, and struct methods
        foreach (decl; decls) {
            if (auto funcDecl = cast(FunctionDecl)decl) {
                collectFunction(funcDecl);
            } else if (auto varDecl = cast(VariableDecl)decl) {
                collectGlobalVariable(varDecl);
            } else if (auto structDecl = cast(StructDecl)decl) {
                // Collect methods from struct declarations
                collectStructMethods(structDecl);
            }
        }
    }
    
    /**
     * Collect methods from a struct declaration.
     * Methods are registered with mangled names: StructName_methodName
     */
    private void collectStructMethods(StructDecl structDecl) {
        foreach (member; structDecl.members) {
            if (auto funcDecl = cast(FunctionDecl)member) {
                if (funcDecl.isMethod) {
                    collectMethod(structDecl, funcDecl);
                }
            }
        }
    }
    
    /**
     * Collect a struct method, adding hidden 'this' parameter.
     */
    private void collectMethod(StructDecl structDecl, FunctionDecl method) {
        // Build signature with hidden 'this' pointer as first parameter
        FuncSig sig;
        
        // 'this' is an i32 (pointer to struct)
        sig.params = [ValType.i32];
        
        // Add the declared parameters
        sig.params ~= method.parameters.map!(p => dTypeToValType(p.type)).array;
        
        if (!isVoidType(method.returnType)) {
            sig.results = [dTypeToValType(method.returnType)];
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
        
        // Generate mangled name
        string mangledName = structDecl.name ~ "_" ~ method.name;
        
        // Create function info
        FuncInfo info;
        info.name = mangledName;  // Use mangled name for index lookups
        info.decl = method;
        info.typeIndex = tIdx;
        info.isImport = false;
        info.structParent = structDecl;  // Track parent struct for codegen
        
        funcIndex[mangledName] = cast(uint)functions.length;
        functions ~= info;
    }
    
    /**
     * Collect a global variable, evaluating struct initializers to data section
     */
    private void collectGlobalVariable(VariableDecl decl) {
        // Check if it's a struct type with an initializer
        if (auto userType = cast(UserType)decl.type) {
            // Resolve declaration if needed
            if (!userType.declaration) {
                auto typeSymbol = symbolTable.lookupSymbol(userType.name);
                if (typeSymbol && typeSymbol.kind == SymbolKind.Type) {
                    userType.declaration = typeSymbol.declaration;
                }
            }
            
            if (auto structDecl = cast(StructDecl)userType.declaration) {
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
            }
        }
    }
    
    private void collectImportedFunction(ImportedFunctionDecl decl) {
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
    }
    
    private void collectFunction(FunctionDecl decl) {
        // Skip CTFE-only functions that use:
        // - variadic intrinsics (like __writeln) - until we implement variadic args struct
        // - __ctfe_runtime module - until we implement host linking for it
        // Non-variadic CTFE calls (like __ctfe_print_i32) become imports.
        if (isCtfeOnlyFunction(decl)) {
            if (usesVariadicCTFE(decl) || usesCTFERuntime(decl.body_)) {
                return;
            }
        }
        
        // Skip functions that return non-basic types (e.g., string-returning CTFE functions)
        if (!canEmitType(decl.returnType)) {
            return;
        }
        
        // Scan for slice types to enable array support (__alloc, etc.)
        scanForSliceTypes(decl);
        
        // Build signature
        FuncSig sig;
        
        // Check for large return type (struct or static array)
        bool largeReturn = isLargeReturnType(decl.returnType);
        
        import std.stdio : stderr;
        
        if (largeReturn) {
            // Add hidden __result pointer as first parameter
            sig.params = [ValType.i32];
            sig.params ~= decl.parameters.map!(p => dTypeToValType(p.type)).array;
            // No result - caller reads from __result address
        } else {
            sig.params = decl.parameters.map!(p => dTypeToValType(p.type)).array;
            
            auto retType = dTypeToValType(decl.returnType);
            if (retType != ValType.i32 || !isVoidType(decl.returnType)) {
                // Non-void return
                if (!isVoidType(decl.returnType)) {
                    sig.results = [retType];
                }
            }
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
        
        // Add function
        FuncInfo info;
        info.name = decl.name;
        info.typeIndex = tIdx;
        info.decl = decl;
        info.exported = true;  // Export all for now
        
        funcIndex[decl.name] = cast(uint)functions.length;
        functions ~= info;
    }
    
    /**
     * Check if a type can be emitted to WASM (basic types only for now)
     */
    private bool canEmitType(Type t) {
        // Void is OK
        if (isVoidType(t)) return true;
        
        // Basic types are OK
        if (cast(BasicType)t) return true;
        
        // Array/slice types are OK (emitted as pointer to slice struct)
        if (cast(ArrayType)t) return true;
        
        // UserTypes (structs) are OK - returned via hidden pointer
        if (auto userType = cast(UserType)t) {
            return true;
        }
        
        return false;
    }
    
    private bool isVoidType(Type t) {
        auto basic = cast(BasicType)t;
        return basic && basic.kind == BasicType.Kind.Void;
    }
    
    /**
     * Check if a return type requires hidden __result parameter
     * (structs and static arrays are too large to return in a register)
     */
    bool isLargeReturnType(Type t) {
        if (t is null) return false;
        
        // UserType (struct)
        if (auto userType = cast(UserType)t) {
            if (!userType.declaration) {
                auto sym = symbolTable.lookupSymbol(userType.name);
                if (sym && sym.kind == SymbolKind.Type) {
                    userType.declaration = sym.declaration;
                }
            }
            if (cast(StructDecl)userType.declaration) {
                return true;
            }
        }
        
        // Static array (int[4])
        if (auto arrType = cast(ArrayType)t) {
            if (arrType.arraySize !is null) {
                return true;  // Static array
            }
        }
        
        return false;
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
        } else if (auto returnStmt = cast(ReturnStatement)stmt) {
            if (returnStmt.value) scanExpressionForCTFECalls(returnStmt.value);
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
                        // Pre-register all __ctfe_write_* imports that might be needed
                        // We always need newline
                        neededCTFEImports["__ctfe_write_newline"] = true;
                        
                        // Scan arguments to determine which typed writers we need
                        foreach (arg; call.arguments) {
                            if (auto literal = cast(LiteralExpression)arg) {
                                if (literal.value.type == typeid(string)) {
                                    neededCTFEImports["__ctfe_write_str"] = true;
                                } else if (literal.value.type == typeid(long) || 
                                           literal.value.type == typeid(int)) {
                                    neededCTFEImports["__ctfe_write_i32"] = true;
                                } else if (literal.value.type == typeid(bool)) {
                                    neededCTFEImports["__ctfe_write_bool"] = true;
                                }
                            } else {
                                // Non-literal expressions default to i32
                                neededCTFEImports["__ctfe_write_i32"] = true;
                            }
                        }
                    } else {
                        neededCTFEImports[ident.name] = true;
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
        if (usesCTFERuntime(decl.body_)) return true;
        return containsOnlyCtfeIntrinsics(decl.body_);
    }
    
    /**
     * Check if a function uses variadic CTFE functions (like __writeln)
     * These require special handling and are still interpreted for now.
     */
    private bool usesVariadicCTFE(FunctionDecl decl) {
        if (!decl.body_) return false;
        return statementUsesVariadicCTFE(decl.body_);
    }
    
    private bool statementUsesVariadicCTFE(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                if (statementUsesVariadicCTFE(s)) return true;
            }
            return false;
        }
        if (auto exprStmt = cast(ExpressionStatement)stmt) {
            return expressionUsesVariadicCTFE(exprStmt.expression);
        }
        if (auto returnStmt = cast(ReturnStatement)stmt) {
            if (returnStmt.value) return expressionUsesVariadicCTFE(returnStmt.value);
        }
        return false;
    }
    
    private bool expressionUsesVariadicCTFE(Expression expr) {
        if (auto call = cast(CallExpression)expr) {
            if (auto ident = cast(IdentifierExpression)call.function_) {
                // __writeln is lowered to typed calls, so it's no longer "variadic" for emission purposes
                if (ident.name == "__writeln") {
                    return false;
                }
                auto symbol = symbolTable.lookupSymbol(ident.name);
                if (symbol && symbol.isCTFEOnly && symbol.isVariadic) {
                    return true;
                }
            }
        }
        return false;
    }
    
    /**
     * Check if a statement uses __ctfe_runtime calls.
     */
    private bool usesCTFERuntime(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                if (usesCTFERuntime(s)) return true;
            }
            return false;
        }
        
        if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            if (varDecl.initializer && expressionUsesCTFERuntime(varDecl.initializer)) {
                return true;
            }
            return false;
        }
        
        if (auto exprStmt = cast(ExpressionStatement)stmt) {
            return expressionUsesCTFERuntime(exprStmt.expression);
        }
        
        if (auto returnStmt = cast(ReturnStatement)stmt) {
            if (returnStmt.value) {
                return expressionUsesCTFERuntime(returnStmt.value);
            }
            return false;
        }
        
        return false;
    }
    
    /**
     * Check if an expression uses __ctfe_runtime.
     */
    private bool expressionUsesCTFERuntime(Expression expr) {
        if (auto call = cast(CallExpression)expr) {
            if (auto member = cast(MemberExpression)call.function_) {
                if (auto obj = cast(IdentifierExpression)member.object) {
                    if (obj.name == "__ctfe_runtime") {
                        return true;
                    }
                }
            }
            // Check arguments too
            foreach (arg; call.arguments) {
                if (expressionUsesCTFERuntime(arg)) return true;
            }
        }
        
        if (auto member = cast(MemberExpression)expr) {
            return expressionUsesCTFERuntime(member.object);
        }
        
        if (auto binary = cast(BinaryExpression)expr) {
            return expressionUsesCTFERuntime(binary.left) || expressionUsesCTFERuntime(binary.right);
        }
        
        return false;
    }
    
    private bool containsOnlyCtfeIntrinsics(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                if (!containsOnlyCtfeIntrinsics(s)) return false;
            }
            return true;
        }
        
        if (auto exprStmt = cast(ExpressionStatement)stmt) {
            if (auto call = cast(CallExpression)exprStmt.expression) {
                if (auto ident = cast(IdentifierExpression)call.function_) {
                    // Check if calling a CTFE-only function
                    auto symbol = symbolTable.lookupSymbol(ident.name);
                    if (symbol && symbol.isCTFEOnly) return true;
                }
            }
            return false;  // Other expressions need WASM
        }
        
        if (auto returnStmt = cast(ReturnStatement)stmt) {
            // Empty return (void) is OK for CTFE-only functions
            return returnStmt.value is null;
        }
        
        return false;  // Other statement types need WASM
    }
    
    package ValType dTypeToValType(Type t) {
        // Struct types are passed as i32 pointers
        if (auto userType = cast(UserType)t) {
            return ValType.i32;  // Pointer to struct
        }
        
        // Array/slice types are also passed as i32 pointers (to the slice struct)
        if (auto arrayType = cast(ArrayType)t) {
            return ValType.i32;  // Pointer to slice struct
        }
        
        auto basic = cast(BasicType)t;
        if (!basic) {
            throw new EmitError("Non-basic types not yet supported", t.toString());
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
     * The shadow stack grows downward from top of memory (64KB for 1 page).
     * Used for struct locals that can't fit in WASM locals.
     */
    private void addShadowStackGlobal() {
        spGlobal = cast(uint)globals.length;
        GlobalInfo sp;
        sp.type = ValType.i32;
        sp.mutable = true;
        sp.initValue = 65536;  // Top of first memory page (stack grows down)
        sp.name = "__sp";
        globals ~= sp;
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
            // Look up the builtin to get its signature
            auto symbol = symbolTable.lookupSymbol(name);
            if (!symbol) continue;
            
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
                case "__ctfe_write_str":
                    sig.params = [ValType.i32, ValType.i32];  // ptr, len
                    break;
                case "__ctfe_write_bool":
                    sig.params = [ValType.i32];
                    break;
                case "__ctfe_write_newline":
                    sig.params = [];
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
        
        // Rebuild funcIndex
        funcIndex.clear();
        foreach (i, ref f; functions) {
            funcIndex[f.name] = cast(uint)i;
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
        auto sectionGlobals = globals.map!(g => GlobalInfo_(g.type, g.mutable, g.initValue)).array;
        
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
                // Index: local functions start after imports
                funcExports ~= FuncExport(f.name, cast(uint)imports.length + cast(uint)i);
            }
        }
        
        // Build global exports
        GlobalExport[] globalExports;
        if (needsArraySupport) {
            globalExports ~= GlobalExport("__heap_ptr", heapPtrGlobal);
        }
        
        if (auto content = buildExportSection(funcExports, true, globalExports))
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
        // Handle built-in functions
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
        
        // Emit body
        if (f.decl.body_) {
            ctx.emitStatement(body_, f.decl.body_);
        }
        
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
            leb128u(body_, ARRAY_PTR_OFFSET);
            body_ ~= Op.local_set;
            leb128u(body_, 2);  // s1_ptr
            
            body_ ~= Op.local_get;
            leb128u(body_, 0);  // s1
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, ARRAY_LEN_OFFSET);
            body_ ~= Op.local_set;
            leb128u(body_, 3);  // s1_len
            
            // Load s2.ptr and s2.len
            body_ ~= Op.local_get;
            leb128u(body_, 1);  // s2
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, ARRAY_PTR_OFFSET);
            body_ ~= Op.local_set;
            leb128u(body_, 4);  // s2_ptr
            
            body_ ~= Op.local_get;
            leb128u(body_, 1);  // s2
            body_ ~= Op.i32_load;
            leb128u(body_, 2);  // align
            leb128u(body_, ARRAY_LEN_OFFSET);
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
            
            // buffer = alloc(new_len)
            body_ ~= Op.local_get;
            leb128u(body_, 6);
            body_ ~= Op.call;
            leb128u(body_, allocFuncIndex);
            body_ ~= Op.local_set;
            leb128u(body_, 7);  // buffer
            
            // result = alloc(12)  // Array struct size
            body_ ~= Op.i32_const;
            leb128s(body_, ARRAY_STRUCT_SIZE);
            body_ ~= Op.call;
            leb128u(body_, allocFuncIndex);
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
            leb128u(body_, ARRAY_PTR_OFFSET);
            
            // result.len = new_len
            body_ ~= Op.local_get;
            leb128u(body_, 8);  // result
            body_ ~= Op.local_get;
            leb128u(body_, 6);  // new_len
            body_ ~= Op.i32_store;
            leb128u(body_, 2);  // align
            leb128u(body_, ARRAY_LEN_OFFSET);
            
            // result.cap = new_len
            body_ ~= Op.local_get;
            leb128u(body_, 8);  // result
            body_ ~= Op.local_get;
            leb128u(body_, 6);  // new_len
            body_ ~= Op.i32_store;
            leb128u(body_, 2);  // align
            leb128u(body_, ARRAY_CAP_OFFSET);
            
            // return result
            body_ ~= Op.local_get;
            leb128u(body_, 8);
            body_ ~= Op.end;
            
        } else if (f.name == "__eval") {
            // __eval() -> i32
            // Evaluates the stored expression and returns the result pointer
            
            leb128u(body_, 0);  // No locals
            
            // Create a context to emit the expression
            auto ctx = new EvalContext(this);
            ctx.emitExpression(body_, evalExpression);
            
            body_ ~= Op.end;
            
        } else {
            throw new EmitError("Unknown built-in function: " ~ f.name);
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
    package uint getFuncIndex(string name) {
        // Check if it's an imported function
        if (auto idx = name in importIndex) {
            return *idx;  // Import indices start at 0
        }
        
        // Check if it's a local function
        if (auto idx = name in funcIndex) {
            // Local function index + number of imports
            return cast(uint)imports.length + *idx;
        }
        
        throw new EmitError("Unknown function: " ~ name);
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
        ubyte[ARRAY_STRUCT_SIZE] structData;
        // Little-endian i32 values
        *cast(uint*)&structData[ARRAY_PTR_OFFSET] = dataOffset;
        *cast(uint*)&structData[ARRAY_LEN_OFFSET] = len;
        *cast(uint*)&structData[ARRAY_CAP_OFFSET] = len;
        
        uint structOffset = addData(structData[]);
        
        arrayLiterals[s] = ArrayLiteralInfo(structOffset, dataOffset, len);
        
        return structOffset;
    }
    
    /**
     * Register a manifest constant array (from import() or array literal CTFE)
     * and return the struct address in the data section.
     */
    package uint registerManifestArray(ManifestConstantDecl manifest) {
        import codegen.wasm.types : ARRAY_STRUCT_SIZE, ARRAY_PTR_OFFSET, ARRAY_LEN_OFFSET, ARRAY_CAP_OFFSET;
        
        // Check if already registered
        if (manifest.name in manifestArrayAddrs) {
            return manifestArrayAddrs[manifest.name];
        }
        
        needsArraySupport = true;
        
        // Add the raw bytes to data section
        uint dataOffset = addData(manifest.ctfeArrayBytes);
        uint len = cast(uint)manifest.ctfeArrayBytes.length;
        
        // Create the Array struct: { ptr, len, cap }
        ubyte[ARRAY_STRUCT_SIZE] structData;
        *cast(uint*)&structData[ARRAY_PTR_OFFSET] = dataOffset;
        *cast(uint*)&structData[ARRAY_LEN_OFFSET] = len;
        *cast(uint*)&structData[ARRAY_CAP_OFFSET] = len;
        
        uint structOffset = addData(structData[]);
        manifestArrayAddrs[manifest.name] = structOffset;
        
        return structOffset;
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
        } else if (auto binary = cast(BinaryExpression)expr) {
            emitBinary(out_, binary);
        } else if (auto call = cast(CallExpression)expr) {
            emitCallExpr(out_, call);
        } else {
            throw new EmitError("Unsupported expression in __eval: " ~ expr.toString());
        }
    }
    
    void emitCallExpr(ref Appender!(ubyte[]) out_, CallExpression expr) {
        auto ident = cast(IdentifierExpression)expr.function_;
        if (!ident) {
            throw new EmitError("Unsupported call expression in __eval");
        }
        
        if (ident.name == "__text") {
            // __text(expr) - convert integer expression to string at compile time
            if (expr.arguments.length != 1) {
                throw new EmitError("__text requires exactly one argument");
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
            throw new EmitError("Unknown intrinsic in __eval: " ~ ident.name);
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
            throw new EmitError("Expected integer in __text argument");
        }
        
        if (auto ident = cast(IdentifierExpression)expr) {
            auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.isConstant) {
                if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                    if (!manifest.isStringType) {
                        // Lazy evaluation via resolver
                        return emitter.symbolTable.resolveManifestValue(manifest);
                    }
                }
            }
            throw new EmitError("Unknown or non-integer identifier in __text: " ~ ident.name);
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
                    throw new EmitError("Concat not supported in __text argument");
            }
        }
        
        throw new EmitError("Cannot evaluate __text argument: " ~ expr.toString());
    }
    
    void emitLiteral(ref Appender!(ubyte[]) out_, LiteralExpression expr) {
        if (expr.value.type == typeid(string)) {
            // String literal: emit pointer to Array struct
            string s = expr.value.get!string();
            uint structAddr = emitter.registerArrayLiteral(s);
            out_ ~= Op.i32_const;
            leb128s(out_, structAddr);
        } else if (expr.value.type == typeid(long)) {
            out_ ~= Op.i32_const;
            leb128s(out_, expr.value.get!long());
        } else {
            throw new EmitError("Unsupported literal type in __eval");
        }
    }
    
    void emitIdentifier(ref Appender!(ubyte[]) out_, IdentifierExpression expr) {
        // Must be a manifest constant - evaluate lazily
        auto symbol = emitter.symbolTable.lookupSymbol(expr.name);
        if (symbol && symbol.isConstant) {
            if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                // Trigger lazy evaluation if needed
                if (manifest.isStringType) {
                    if (!manifest.ctfeComplete) {
                        emitter.symbolTable.resolveManifestValue(manifest);
                    }
                    uint structAddr = emitter.registerArrayLiteral(manifest.ctfeStringValue);
                    out_ ~= Op.i32_const;
                    leb128s(out_, structAddr);
                } else {
                    out_ ~= Op.i32_const;
                    leb128s(out_, emitter.symbolTable.resolveManifestValue(manifest));
                }
                return;
            }
        }
        throw new EmitError("Unknown identifier in __eval: " ~ expr.name);
    }
    
    void emitBinary(ref Appender!(ubyte[]) out_, BinaryExpression expr) {
        if (expr.operator == BinaryExpression.Operator.Concat) {
            emitArrayConcat(out_, expr);
        } else {
            throw new EmitError("Unsupported binary operator in __eval");
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
