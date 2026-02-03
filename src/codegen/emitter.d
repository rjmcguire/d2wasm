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

import codegen.wasm;
import ast.nodes;
import ast.statements;
import ast.expressions;
import semantic.symbol_table;

import std.array : Appender, array;
import std.algorithm : map, canFind;
import std.conv : to;
import std.format : format;

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
// Function Signature (for type section)
//==============================================================================

struct FuncSig {
    ValType[] params;
    ValType[] results;
    
    bool opEquals(const FuncSig other) const {
        return params == other.params && results == other.results;
    }
    
    size_t toHash() const nothrow @safe {
        size_t h = 0;
        foreach (p; params) h = h * 31 + p;
        foreach (r; results) h = h * 31 + r;
        return h;
    }
}

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
// Imported Function Info
//==============================================================================

struct ImportInfo {
    string moduleName;   // WASM module (e.g., "env", "console")
    string fieldName;    // Function name
    uint typeIndex;      // Index into type section
}

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
    private {
        // Output buffer
        Appender!(ubyte[]) output;
        
        // Collected data
        FuncSig[] types;
        uint[FuncSig] typeIndex;
        FuncInfo[] functions;
        uint[string] funcIndex;
        
        // Imported functions (from WASM host)
        ImportInfo[] imports;
        uint[string] importIndex;  // Maps function name to import index
        
        // Built-in functions
        bool hasBuiltins = false;
        uint allocFuncIndex;
        uint concatFuncIndex;
        
        // State
        EmitPhase phase = EmitPhase.init;
        string lastError;
        
        // Symbol table for lookups
        SymbolTable symbolTable;
        
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
        uint spGlobal;       // Index of $sp (shadow stack pointer) global
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
        
        // Whether we need array support (allocator, etc.)
        bool needsArraySupport = false;
    }
    
    this(SymbolTable symbolTable) {
        this.symbolTable = symbolTable;
        this.nextDataOffset = MEMORY_RESERVED;  // Start after reserved area
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
                    if (manifest.ctfeComplete && !manifest.isStringType) {
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
        // Skip CTFE-only functions (those containing CTFE intrinsics like __writeln)
        if (isCtfeOnlyFunction(decl)) {
            return;
        }
        
        // Skip functions that return non-basic types (e.g., string-returning CTFE functions)
        if (!canEmitType(decl.returnType)) {
            return;
        }
        
        // Build signature
        FuncSig sig;
        sig.params = decl.parameters.map!(p => dTypeToValType(p.type)).array;
        
        auto retType = dTypeToValType(decl.returnType);
        if (retType != ValType.i32 || !isVoidType(decl.returnType)) {
            // Non-void return
            if (!isVoidType(decl.returnType)) {
                sig.results = [retType];
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
        
        // UserType "string" is NOT OK (CTFE-only)
        if (auto userType = cast(UserType)t) {
            return false;  // String and other user types can't be emitted yet
        }
        
        return false;
    }
    
    private bool isVoidType(Type t) {
        auto basic = cast(BasicType)t;
        return basic && basic.kind == BasicType.Kind.Void;
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
                    // __writeln is a CTFE-only intrinsic
                    if (ident.name == "__writeln") return true;
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
    
    private ValType dTypeToValType(Type t) {
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
        if (types.length == 0) return;
        
        Appender!(ubyte[]) section;
        
        // Type count
        leb128u(section, types.length);
        
        foreach (sig; types) {
            // Function type marker
            section ~= cast(ubyte)0x60;
            
            // Parameters
            leb128u(section, sig.params.length);
            foreach (p; sig.params) {
                section ~= cast(ubyte)p;
            }
            
            // Results
            leb128u(section, sig.results.length);
            foreach (r; sig.results) {
                section ~= cast(ubyte)r;
            }
        }
        
        emitSection(Section.type, section.data);
    }
    
    //==========================================================================
    // Import Section
    //==========================================================================
    
    private void emitImportSection() {
        if (imports.length == 0) return;
        
        Appender!(ubyte[]) section;
        
        // Import count
        leb128u(section, imports.length);
        
        foreach (imp; imports) {
            // Module name (length-prefixed string)
            leb128u(section, imp.moduleName.length);
            section ~= cast(ubyte[])imp.moduleName;
            
            // Field name (length-prefixed string)
            leb128u(section, imp.fieldName.length);
            section ~= cast(ubyte[])imp.fieldName;
            
            // Import kind: 0x00 = function
            section ~= cast(ubyte)0x00;
            
            // Type index
            leb128u(section, imp.typeIndex);
        }
        
        emitSection(Section.import_, section.data);
    }
    
    //==========================================================================
    // Function Section
    //==========================================================================
    
    private void emitFunctionSection() {
        if (functions.length == 0) return;
        
        Appender!(ubyte[]) section;
        
        // Function count
        leb128u(section, functions.length);
        
        foreach (f; functions) {
            leb128u(section, f.typeIndex);
        }
        
        emitSection(Section.function_, section.data);
    }
    
    //==========================================================================
    // Memory Section
    //==========================================================================
    
    private void emitMemorySection() {
        // Always emit memory for now (needed for data section)
        Appender!(ubyte[]) section;
        
        // 1 memory
        leb128u(section, 1);
        
        // Limits: min pages, no max
        section ~= cast(ubyte)0x00;  // flags: no max
        leb128u(section, memoryPages);
        
        emitSection(Section.memory, section.data);
    }
    
    //==========================================================================
    // Global Section
    //==========================================================================
    
    private void emitGlobalSection() {
        if (globals.length == 0) return;
        
        Appender!(ubyte[]) section;
        
        // Global count
        leb128u(section, globals.length);
        
        foreach (g; globals) {
            // Type
            section ~= cast(ubyte)g.type;
            // Mutability: 0 = const, 1 = mutable
            section ~= cast(ubyte)(g.mutable ? 1 : 0);
            
            // Init expression
            if (g.type == ValType.i32) {
                section ~= Op.i32_const;
                leb128s(section, g.initValue);
            } else if (g.type == ValType.i64) {
                section ~= Op.i64_const;
                leb128s(section, g.initValue);
            }
            section ~= Op.end;
        }
        
        emitSection(Section.global, section.data);
    }
    
    //==========================================================================
    // Export Section
    //==========================================================================
    
    private void emitExportSection() {
        Appender!(ubyte[]) section;
        
        // Count exports (functions + memory + globals we want to export)
        uint exportCount = 0;
        foreach (f; functions) {
            if (f.exported) exportCount++;
        }
        exportCount++;  // Memory export
        if (needsArraySupport) {
            exportCount++;  // Export heap_ptr for debugging
        }
        
        leb128u(section, exportCount);
        
        // Export functions
        foreach (i, f; functions) {
            if (!f.exported) continue;
            
            // Name
            leb128u(section, f.name.length);
            section ~= cast(ubyte[])f.name;
            
            // Kind: function
            section ~= cast(ubyte)ExportKind.func;
            
            // Index: local functions start after imports
            leb128u(section, cast(uint)imports.length + cast(uint)i);
        }
        
        // Export memory
        {
            string memName = "memory";
            leb128u(section, memName.length);
            section ~= cast(ubyte[])memName;
            section ~= cast(ubyte)ExportKind.memory;
            leb128u(section, 0);  // Memory index 0
        }
        
        // Export heap_ptr global (for CTFE debugging)
        if (needsArraySupport) {
            string hpName = "__heap_ptr";
            leb128u(section, hpName.length);
            section ~= cast(ubyte[])hpName;
            section ~= cast(ubyte)ExportKind.global;
            leb128u(section, heapPtrGlobal);
        }
        
        emitSection(Section.export_, section.data);
    }
    
    //==========================================================================
    // Code Section
    //==========================================================================
    
    private void emitCodeSection() {
        if (functions.length == 0) return;
        
        Appender!(ubyte[]) section;
        
        // Function count
        leb128u(section, functions.length);
        
        foreach (f; functions) {
            auto body_ = emitFunctionBody(f);
            
            // Body size
            leb128u(section, body_.length);
            section ~= body_;
        }
        
        emitSection(Section.code, section.data);
    }
    
    private ubyte[] emitFunctionBody(FuncInfo f) {
        // Handle built-in functions
        if (f.decl is null) {
            return emitBuiltinBody(f);
        }
        
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
        
        return body_.data;
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
        
        Appender!(ubyte[]) section;
        
        // Segment count
        leb128u(section, dataEntries.length);
        
        foreach (entry; dataEntries) {
            // Active segment, memory 0
            section ~= cast(ubyte)0x00;
            
            // Offset expression: i32.const <offset>
            section ~= Op.i32_const;
            leb128s(section, entry.offset);
            section ~= Op.end;
            
            // Data
            leb128u(section, entry.data.length);
            section ~= entry.data;
        }
        
        emitSection(Section.data, section.data);
    }
    
    /**
     * Add a data entry (string literal, etc.)
     * Returns the memory offset
     */
    uint addData(ubyte[] data) {
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
    uint getFuncIndex(string name) {
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
    uint registerArrayLiteral(string s) {
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
// Function Context - Handles local variables and code emission
//==============================================================================

private class FuncContext {
    BinaryEmitter emitter;
    FuncInfo func;
    
    // Local variables (parameters + locals)
    ValType[] localTypes;
    uint[string] localIndex;
    uint paramCount;
    
    // Shadow stack for struct locals
    struct StructLocalInfo {
        uint frameOffset;      // Offset from frame pointer (FP)
        StructDecl structDecl; // The struct type
    }
    StructLocalInfo[string] structLocals;
    
    // Shadow stack for slice locals (ptr, length, capacity = 12 bytes)
    struct SliceLocalInfo {
        uint frameOffset;      // Offset from frame pointer (FP) for the slice struct
        uint dataOffset;       // Offset for the backing data (if literal initializer)
        uint dataSize;         // Size of backing data in bytes
        Type elementType;      // Element type of the slice
    }
    SliceLocalInfo[string] sliceLocals;
    
    uint frameSize = 0;        // Total size of struct/slice locals on shadow stack
    uint savedSpLocal;         // Local index to store saved SP (for epilogue restore)
    uint fpLocal;              // Local index for frame pointer (stable, never changes)
    
    // Struct parameters (passed as pointers)
    struct StructParamInfo {
        uint localIndex;       // WASM local index holding the pointer
        StructDecl structDecl; // The struct type
    }
    StructParamInfo[string] structParams;
    
    // Block depth for br instructions
    uint blockDepth = 0;
    
    // Method info: non-null structParent means we're in a method with hidden 'this'
    uint thisLocalIndex;  // Local index of hidden 'this' parameter (for methods)
    
    this(FuncInfo f, BinaryEmitter e) {
        this.func = f;
        this.emitter = e;
        
        uint localOffset = 0;
        
        // For methods, add hidden 'this' pointer as first parameter
        if (f.structParent !is null) {
            localTypes ~= ValType.i32;  // 'this' is a pointer (i32)
            thisLocalIndex = 0;
            localOffset = 1;
            
            // Register 'this' as a struct param so this.x works
            StructParamInfo info;
            info.localIndex = 0;
            info.structDecl = f.structParent;
            structParams["this"] = info;
        }
        
        // Parameters are the next locals
        foreach (i, p; f.decl.parameters) {
            auto vt = e.dTypeToValType(p.type);
            localIndex[p.name] = cast(uint)(i + localOffset);
            localTypes ~= vt;
            
            // Track struct parameters
            if (auto userType = cast(UserType)p.type) {
                // Resolve struct declaration
                if (!userType.declaration) {
                    auto typeSymbol = e.symbolTable.lookupSymbol(userType.name);
                    if (typeSymbol && typeSymbol.kind == SymbolKind.Type) {
                        userType.declaration = typeSymbol.declaration;
                    }
                }
                if (auto structDecl = cast(StructDecl)userType.declaration) {
                    StructParamInfo info;
                    info.localIndex = cast(uint)(i + localOffset);
                    info.structDecl = structDecl;
                    structParams[p.name] = info;
                }
            }
        }
        paramCount = cast(uint)(f.decl.parameters.length + localOffset);
    }
    
    /**
     * Collect local variable declarations from statements
     */
    void collectLocals(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                collectLocals(s);
            }
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            // Check if it's a struct type
            if (auto userType = cast(UserType)varDecl.type) {
                // Resolve the struct declaration
                if (!userType.declaration) {
                    auto typeSymbol = emitter.symbolTable.lookupSymbol(userType.name);
                    if (typeSymbol && typeSymbol.kind == SymbolKind.Type) {
                        userType.declaration = typeSymbol.declaration;
                    }
                }
                
                if (auto structDecl = cast(StructDecl)userType.declaration) {
                    // Struct local - allocate on shadow stack
                    // Align frameSize to struct's alignment (assume 4 for now)
                    frameSize = (frameSize + 3) & ~3;
                    
                    StructLocalInfo info;
                    info.frameOffset = frameSize;
                    info.structDecl = structDecl;
                    structLocals[varDecl.name] = info;
                    
                    frameSize += structDecl.structSize;
                    return;
                }
            }
            
            // Check if it's a slice/array type
            if (auto arrayType = cast(ArrayType)varDecl.type) {
                // Slice local - allocate 12 bytes for slice struct (ptr, length, capacity)
                frameSize = (frameSize + 3) & ~3;  // Align to 4 bytes
                
                SliceLocalInfo info;
                info.frameOffset = frameSize;
                info.elementType = arrayType.elementType;
                
                // Slice struct is 12 bytes (ptr: i32, length: i32, capacity: i32)
                frameSize += 12;
                
                // If initialized with array literal, also allocate space for data
                if (auto arrayLit = cast(ArrayLiteralExpression)varDecl.initializer) {
                    frameSize = (frameSize + 3) & ~3;  // Align data
                    info.dataOffset = frameSize;
                    
                    // Calculate data size based on element type and count
                    size_t elemSize = arrayType.elementType.size();
                    if (elemSize == 0) elemSize = 4;  // Default to 4 for i32
                    info.dataSize = cast(uint)(elemSize * arrayLit.elements.length);
                    
                    frameSize += info.dataSize;
                }
                
                sliceLocals[varDecl.name] = info;
                return;
            }
            
            // Regular local - add to WASM locals
            auto vt = emitter.dTypeToValType(varDecl.type);
            localIndex[varDecl.name] = cast(uint)localTypes.length;
            localTypes ~= vt;
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            collectLocals(ifStmt.thenStatement);
            if (ifStmt.elseStatement) {
                collectLocals(ifStmt.elseStatement);
            }
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            collectLocals(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            if (forStmt.init) collectLocals(forStmt.init);
            collectLocals(forStmt.body_);
        }
    }
    
    /**
     * Finalize locals after collection - add saved SP and FP locals if needed
     */
    void finalizeLocals() {
        if (frameSize > 0) {
            // Need locals for saved SP (epilogue restore) and FP (stable frame access)
            savedSpLocal = cast(uint)localTypes.length;
            localTypes ~= ValType.i32;
            fpLocal = cast(uint)localTypes.length;
            localTypes ~= ValType.i32;
        }
    }
    
    /**
     * Emit shadow stack prologue (if function has struct locals)
     * 
     * savedSp = $sp
     * $sp = $sp - frameSize
     * FP = $sp   (frame pointer - stable reference for locals)
     */
    void emitPrologue(ref Appender!(ubyte[]) out_) {
        if (frameSize == 0) return;
        
        // savedSp = global.get $sp
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.local_set;
        leb128u(out_, savedSpLocal);
        
        // $sp = $sp - frameSize
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, frameSize);
        out_ ~= Op.i32_sub;
        out_ ~= Op.global_set;
        leb128u(out_, emitter.spGlobal);
        
        // FP = $sp (frame pointer for stable local access)
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.local_set;
        leb128u(out_, fpLocal);
    }
    
    /**
     * Emit shadow stack epilogue (restores SP before implicit return)
     * 
     * $sp = savedSp
     */
    void emitEpilogue(ref Appender!(ubyte[]) out_) {
        if (frameSize == 0) return;
        
        // $sp = savedSp
        out_ ~= Op.local_get;
        leb128u(out_, savedSpLocal);
        out_ ~= Op.global_set;
        leb128u(out_, emitter.spGlobal);
    }
    
    /**
     * Emit local declarations (non-parameter locals)
     */
    void emitLocalDecls(ref Appender!(ubyte[]) out_) {
        auto nonParamLocals = localTypes[paramCount .. $];
        
        if (nonParamLocals.length == 0) {
            leb128u(out_, 0);  // 0 local groups
            return;
        }
        
        // Group consecutive same-type locals
        struct LocalGroup { uint count; ValType type; }
        LocalGroup[] groups;
        
        ValType currentType = nonParamLocals[0];
        uint currentCount = 1;
        
        foreach (t; nonParamLocals[1 .. $]) {
            if (t == currentType) {
                currentCount++;
            } else {
                groups ~= LocalGroup(currentCount, currentType);
                currentType = t;
                currentCount = 1;
            }
        }
        groups ~= LocalGroup(currentCount, currentType);
        
        // Emit groups
        leb128u(out_, groups.length);
        foreach (g; groups) {
            leb128u(out_, g.count);
            out_ ~= cast(ubyte)g.type;
        }
    }
    
    //==========================================================================
    // Statement Emission
    //==========================================================================
    
    void emitStatement(ref Appender!(ubyte[]) out_, Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                emitStatement(out_, s);
            }
        } else if (auto returnStmt = cast(ReturnStatement)stmt) {
            emitReturn(out_, returnStmt);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            emitExpressionStatement(out_, exprStmt);
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            emitIf(out_, ifStmt);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            emitWhile(out_, whileStmt);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            emitFor(out_, forStmt);
        } else if (auto varDecl = cast(VariableDeclarationStatement)stmt) {
            // Check if this is a struct local
            if (varDecl.name in structLocals) {
                emitStructVarDecl(out_, varDecl);
            } else if (varDecl.name in sliceLocals) {
                emitSliceVarDecl(out_, varDecl);
            } else {
                emitVarDecl(out_, varDecl);
            }
        } else {
            throw new EmitError("Unsupported statement type", stmt.toString());
        }
    }
    
    void emitReturn(ref Appender!(ubyte[]) out_, ReturnStatement stmt) {
        if (stmt.value) {
            emitExpression(out_, stmt.value);
        }
        
        // Restore shadow stack before returning
        emitEpilogue(out_);
        
        out_ ~= Op.return_;
    }
    
    void emitExpressionStatement(ref Appender!(ubyte[]) out_, ExpressionStatement stmt) {
        emitExpression(out_, stmt.expression);
        
        // Drop result if expression leaves a value
        if (expressionHasValue(stmt.expression)) {
            out_ ~= Op.drop;
        }
    }
    
    void emitIf(ref Appender!(ubyte[]) out_, IfStatement stmt) {
        // Condition
        emitExpression(out_, stmt.condition);
        
        // if (void block type)
        out_ ~= Op.if_;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        
        // Then branch
        emitStatement(out_, stmt.thenStatement);
        
        // Else branch
        if (stmt.elseStatement) {
            out_ ~= Op.else_;
            emitStatement(out_, stmt.elseStatement);
        }
        
        blockDepth--;
        out_ ~= Op.end;
        
        // If both branches return, code after this is unreachable
        // We need to tell WASM that to satisfy type checking
        if (stmt.elseStatement && 
            alwaysReturns(stmt.thenStatement) && 
            alwaysReturns(stmt.elseStatement)) {
            out_ ~= Op.unreachable;
        }
    }
    
    /**
     * Check if a statement always terminates (return, unreachable, etc.)
     */
    bool alwaysReturns(Statement stmt) {
        if (auto returnStmt = cast(ReturnStatement)stmt) {
            return true;
        }
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                if (alwaysReturns(s)) return true;
            }
            return false;
        }
        if (auto ifStmt = cast(IfStatement)stmt) {
            // if/else returns only if BOTH branches return
            return ifStmt.elseStatement !is null &&
                   alwaysReturns(ifStmt.thenStatement) &&
                   alwaysReturns(ifStmt.elseStatement);
        }
        return false;
    }
    
    void emitWhile(ref Appender!(ubyte[]) out_, WhileStatement stmt) {
        // block (for break)
        out_ ~= Op.block;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        
        // loop
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        
        // Condition
        emitExpression(out_, stmt.condition);
        out_ ~= Op.i32_eqz;  // Invert: break if false
        out_ ~= Op.br_if;
        leb128u(out_, 1);  // Break to outer block
        
        // Body
        emitStatement(out_, stmt.body_);
        
        // Continue: branch back to loop
        out_ ~= Op.br;
        leb128u(out_, 0);  // Back to loop
        
        blockDepth--;
        out_ ~= Op.end;  // End loop
        
        blockDepth--;
        out_ ~= Op.end;  // End block
    }
    
    void emitFor(ref Appender!(ubyte[]) out_, ForStatement stmt) {
        // Init
        if (stmt.init) {
            emitStatement(out_, stmt.init);
        }
        
        // block (for break)
        out_ ~= Op.block;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        
        // loop
        out_ ~= Op.loop;
        out_ ~= cast(ubyte)BlockType.void_;
        blockDepth++;
        
        // Condition (if present)
        if (stmt.condition) {
            emitExpression(out_, stmt.condition);
            out_ ~= Op.i32_eqz;
            out_ ~= Op.br_if;
            leb128u(out_, 1);  // Break to outer block
        }
        
        // Body
        emitStatement(out_, stmt.body_);
        
        // Update
        if (stmt.update) {
            emitExpression(out_, stmt.update);
            if (expressionHasValue(stmt.update)) {
                out_ ~= Op.drop;
            }
        }
        
        // Continue
        out_ ~= Op.br;
        leb128u(out_, 0);
        
        blockDepth--;
        out_ ~= Op.end;  // End loop
        
        blockDepth--;
        out_ ~= Op.end;  // End block
    }
    
    void emitVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto idx = localIndex[stmt.name];
        
        if (stmt.initializer) {
            emitExpression(out_, stmt.initializer);
        } else {
            // Default init to 0
            out_ ~= Op.i32_const;
            leb128s(out_, 0);
        }
        
        out_ ~= Op.local_set;
        leb128u(out_, idx);
    }
    
    /**
     * Emit struct local variable declaration - stores fields to shadow stack
     */
    void emitStructVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto info = structLocals[stmt.name];
        auto structDecl = info.structDecl;
        
        if (!stmt.initializer) {
            // Zero-initialize the struct
            foreach (field; structDecl.fields) {
                // Address: FP + frameOffset + fieldOffset
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + cast(int)field.offset);
                out_ ~= Op.i32_add;
                
                // Value: 0
                out_ ~= Op.i32_const;
                leb128s(out_, 0);
                
                // Store
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;  // alignment log2(4)
                leb128u(out_, 0);          // offset
            }
            return;
        }
        
        // Struct construction: Point(10, 20) or Outer(Inner(1,2), 3)
        if (auto callExpr = cast(CallExpression)stmt.initializer) {
            // Use unified struct init that handles nested structs
            emitStructFieldsInit(out_, structDecl, callExpr.arguments, 
                                EmitAddrMode.fromFP, info.frameOffset);
            return;
        }
        
        // Struct copy: Point b = a (copy from another struct variable)
        if (auto identExpr = cast(IdentifierExpression)stmt.initializer) {
            // Check if source is a local struct
            if (auto srcInfo = identExpr.name in structLocals) {
                // Copy field by field from source to destination
                for (size_t i = 0; i < structDecl.fields.length; i++) {
                    auto field = structDecl.fields[i];
                    
                    // Destination address: FP + destOffset + fieldOffset
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset + cast(int)field.offset);
                    out_ ~= Op.i32_add;
                    
                    // Source value: load from FP + srcOffset + fieldOffset
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, srcInfo.frameOffset + cast(int)field.offset);
                    out_ ~= Op.i32_add;
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    
                    // Store to destination
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                }
                return;
            }
            
            // TODO: copy from global struct
        }
        
        throw new EmitError("Unsupported struct initializer", stmt.initializer.toString());
    }
    
    /**
     * Emit slice local variable declaration
     * Slice struct layout: { ptr: i32, length: i32, capacity: i32 } = 12 bytes
     */
    void emitSliceVarDecl(ref Appender!(ubyte[]) out_, VariableDeclarationStatement stmt) {
        auto info = sliceLocals[stmt.name];
        
        if (!stmt.initializer) {
            // Zero-initialize the slice struct (ptr=0, length=0, capacity=0)
            for (int offset = 0; offset < 12; offset += 4) {
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + offset);
                out_ ~= Op.i32_add;
                out_ ~= Op.i32_const;
                leb128s(out_, 0);
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            }
            return;
        }
        
        // Array literal initializer: [1, 2, 3]
        if (auto arrayLit = cast(ArrayLiteralExpression)stmt.initializer) {
            uint elemCount = cast(uint)arrayLit.elements.length;
            size_t elemSize = info.elementType ? info.elementType.size() : 4;
            if (elemSize == 0) elemSize = 4;
            
            // First, store the data elements at FP + dataOffset
            for (uint i = 0; i < elemCount; i++) {
                // Address: FP + dataOffset + i * elemSize
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.dataOffset + cast(int)(i * elemSize));
                out_ ~= Op.i32_add;
                
                // Value: the element expression
                emitExpression(out_, arrayLit.elements[i]);
                
                // Store
                out_ ~= Op.i32_store;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
            }
            
            // Now initialize the slice struct:
            // ptr = FP + dataOffset
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset);  // slice.ptr offset = 0
            out_ ~= Op.i32_add;
            
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.dataOffset);
            out_ ~= Op.i32_add;  // ptr value = FP + dataOffset
            
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            // length = elemCount
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset + 4);  // slice.length offset = 4
            out_ ~= Op.i32_add;
            
            out_ ~= Op.i32_const;
            leb128s(out_, elemCount);
            
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            // capacity = elemCount
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset + 8);  // slice.capacity offset = 8
            out_ ~= Op.i32_add;
            
            out_ ~= Op.i32_const;
            leb128s(out_, elemCount);
            
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            return;
        }
        
        throw new EmitError("Unsupported slice initializer", stmt.initializer.toString());
    }
    
    //==========================================================================
    // Expression Emission
    //==========================================================================
    
    void emitExpression(ref Appender!(ubyte[]) out_, Expression expr) {
        if (auto literal = cast(LiteralExpression)expr) {
            emitLiteral(out_, literal);
        } else if (auto ident = cast(IdentifierExpression)expr) {
            emitIdentifier(out_, ident);
        } else if (auto binary = cast(BinaryExpression)expr) {
            emitBinary(out_, binary);
        } else if (auto unary = cast(UnaryExpression)expr) {
            emitUnary(out_, unary);
        } else if (auto call = cast(CallExpression)expr) {
            emitCall(out_, call);
        } else if (auto assign = cast(AssignmentExpression)expr) {
            emitAssignment(out_, assign);
        } else if (auto member = cast(MemberExpression)expr) {
            emitMember(out_, member);
        } else if (auto castExpr = cast(CastExpression)expr) {
            emitCast(out_, castExpr);
        } else {
            throw new EmitError("Unsupported expression type", expr.toString());
        }
    }
    
    void emitCast(ref Appender!(ubyte[]) out_, CastExpression expr) {
        // Emit the expression being cast
        emitExpression(out_, expr.expression);
        // For now, most casts are no-ops at WASM level (everything is i32)
    }
    
    void emitMember(ref Appender!(ubyte[]) out_, MemberExpression expr) {
        // Check if this is a Type.sizeof or Type.alignof
        if (auto ident = cast(IdentifierExpression)expr.object) {
            auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
            if (symbol && symbol.kind == SymbolKind.Type) {
                if (expr.memberName == "sizeof") {
                    // Emit the type's size as a constant
                    size_t size = symbol.type.size();
                    out_ ~= Op.i32_const;
                    leb128s(out_, cast(int)size);
                    return;
                } else if (expr.memberName == "alignof") {
                    // Emit the type's alignment as a constant
                    size_t align_ = symbol.type.alignment();
                    out_ ~= Op.i32_const;
                    leb128s(out_, cast(int)align_);
                    return;
                }
            }
            
            // Check if it's a string constant (MSG.length, MSG.ptr)
            if (symbol && symbol.kind == SymbolKind.Variable) {
                if (auto varDecl = cast(VariableDecl)symbol.declaration) {
                    if (auto userType = cast(UserType)varDecl.type) {
                        if (userType.name == "string" && varDecl.initializer) {
                            if (auto lit = cast(LiteralExpression)varDecl.initializer) {
                                if (lit.value.type == typeid(string)) {
                                    string strValue = lit.value.get!string();
                                    uint structAddr = emitter.registerArrayLiteral(strValue);
                                    
                                    if (expr.memberName == "length") {
                                        // Length is at offset 4 in Array struct
                                        out_ ~= Op.i32_const;
                                        leb128s(out_, structAddr + 4);
                                        out_ ~= Op.i32_load;
                                        out_ ~= cast(ubyte)0x02;
                                        leb128u(out_, 0);
                                        return;
                                    } else if (expr.memberName == "ptr") {
                                        out_ ~= Op.i32_const;
                                        leb128s(out_, structAddr);
                                        out_ ~= Op.i32_load;
                                        out_ ~= cast(ubyte)0x02;
                                        leb128u(out_, 0);
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Check if it's a variable with struct type (e.g., P.x where P is a global struct)
            if (symbol && symbol.kind == SymbolKind.Variable) {
                if (auto varDecl = cast(VariableDecl)symbol.declaration) {
                    if (varDecl.ctfeComplete) {
                        // Global struct variable - load field from data section
                        if (auto userType = cast(UserType)varDecl.type) {
                            if (!userType.declaration) {
                                auto typeSymbol = emitter.symbolTable.lookupSymbol(userType.name);
                                if (typeSymbol) userType.declaration = typeSymbol.declaration;
                            }
                            if (auto structDecl = cast(StructDecl)userType.declaration) {
                                auto field = structDecl.getField(expr.memberName);
                                if (field) {
                                    // Load i32 from data section at struct address + field offset
                                    uint address = varDecl.ctfeStructAddress + cast(uint)field.offset;
                                    out_ ~= Op.i32_const;
                                    leb128s(out_, address);
                                    out_ ~= Op.i32_load;
                                    out_ ~= cast(ubyte)0x02;  // alignment (log2 of 4 bytes)
                                    leb128u(out_, 0);  // offset
                                    return;
                                }
                            }
                        }
                    }
                }
            }
            
            // Check if it's a local struct variable (on shadow stack)
            if (auto info = ident.name in structLocals) {
                auto structDecl = info.structDecl;
                auto field = structDecl.getField(expr.memberName);
                if (field) {
                    // Load i32 from frame at FP + frameOffset + fieldOffset
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset + cast(int)field.offset);
                    out_ ~= Op.i32_add;
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;  // alignment log2(4)
                    leb128u(out_, 0);          // offset
                    return;
                }
            }
            
            // Check if it's a struct parameter (pointer passed as i32)
            if (auto info = ident.name in structParams) {
                auto structDecl = info.structDecl;
                auto field = structDecl.getField(expr.memberName);
                if (field) {
                    // Load pointer from local, add field offset, load value
                    out_ ~= Op.local_get;
                    leb128u(out_, info.localIndex);
                    out_ ~= Op.i32_const;
                    leb128s(out_, cast(int)field.offset);
                    out_ ~= Op.i32_add;
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    return;
                }
            }
            
            // Check if it's a slice local (arr.length, arr.ptr, arr.capacity)
            if (auto info = ident.name in sliceLocals) {
                int fieldOffset;
                if (expr.memberName == "ptr") {
                    fieldOffset = 0;
                } else if (expr.memberName == "length") {
                    fieldOffset = 4;
                } else if (expr.memberName == "capacity") {
                    fieldOffset = 8;
                } else {
                    throw new EmitError("Slice has no field '" ~ expr.memberName ~ "'");
                }
                
                // Load from FP + frameOffset + fieldOffset
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
                out_ ~= Op.i32_const;
                leb128s(out_, info.frameOffset + fieldOffset);
                out_ ~= Op.i32_add;
                out_ ~= Op.i32_load;
                out_ ~= cast(ubyte)0x02;
                leb128u(out_, 0);
                return;
            }
        }
        
        // Handle chained member access (o.i.a where object is MemberExpression)
        if (auto innerMember = cast(MemberExpression)expr.object) {
            // Get the type of the inner member to find the field
            // Emit address of inner member, then add field offset and load
            emitMemberAddress(out_, innerMember);
            
            // Now we need to find the field within the type of innerMember
            // Get the struct type of innerMember
            auto innerType = getMemberExpressionType(innerMember);
            if (auto userType = cast(UserType)innerType) {
                if (!userType.declaration) {
                    auto ts = emitter.symbolTable.lookupSymbol(userType.name);
                    if (ts) userType.declaration = ts.declaration;
                }
                if (auto structDecl = cast(StructDecl)userType.declaration) {
                    auto field = structDecl.getField(expr.memberName);
                    if (field) {
                        // Add field offset and load
                        if (field.offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        return;
                    }
                }
            }
        }
        
        throw new EmitError("Member access not yet fully implemented", expr.toString());
    }
    
    /**
     * Emit the ADDRESS of a member expression (for nested access).
     * Leaves address on stack, doesn't load the value.
     */
    void emitMemberAddress(ref Appender!(ubyte[]) out_, MemberExpression expr) {
        if (auto ident = cast(IdentifierExpression)expr.object) {
            // Check struct locals
            if (auto info = ident.name in structLocals) {
                auto structDecl = info.structDecl;
                auto field = structDecl.getField(expr.memberName);
                if (field) {
                    // Emit address: FP + frameOffset + fieldOffset
                    out_ ~= Op.local_get;
                    leb128u(out_, fpLocal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, info.frameOffset + cast(int)field.offset);
                    out_ ~= Op.i32_add;
                    return;
                }
            }
        }
        // Recursive case: object is also a MemberExpression
        if (auto innerMember = cast(MemberExpression)expr.object) {
            emitMemberAddress(out_, innerMember);
            auto innerType = getMemberExpressionType(innerMember);
            if (auto userType = cast(UserType)innerType) {
                if (auto structDecl = cast(StructDecl)userType.declaration) {
                    auto field = structDecl.getField(expr.memberName);
                    if (field && field.offset > 0) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    return;
                }
            }
        }
        throw new EmitError("Cannot compute address of member", expr.toString());
    }
    
    /**
     * Get the type of a member expression (for determining nested field offsets).
     */
    Type getMemberExpressionType(MemberExpression expr) {
        Type objType;
        
        if (auto ident = cast(IdentifierExpression)expr.object) {
            if (auto info = ident.name in structLocals) {
                objType = new UserType(SourceLocation(), info.structDecl.name);
                (cast(UserType)objType).declaration = info.structDecl;
            } else if (auto info = ident.name in structParams) {
                objType = new UserType(SourceLocation(), info.structDecl.name);
                (cast(UserType)objType).declaration = info.structDecl;
            }
        } else if (auto innerMember = cast(MemberExpression)expr.object) {
            objType = getMemberExpressionType(innerMember);
        }
        
        if (auto userType = cast(UserType)objType) {
            if (auto structDecl = cast(StructDecl)userType.declaration) {
                auto field = structDecl.getField(expr.memberName);
                if (field) {
                    return field.type;
                }
            }
        }
        
        return null;
    }
    
    void emitLiteral(ref Appender!(ubyte[]) out_, LiteralExpression expr) {
        if (expr.value.type == typeid(long)) {
            long value = expr.value.get!long();
            // Check for i32 overflow
            if (value > int.max || value < int.min) {
                throw new EmitError(
                    format("Integer literal %d exceeds i32 range [%d, %d]", value, int.min, int.max),
                    "literal emission"
                );
            }
            out_ ~= Op.i32_const;
            leb128s(out_, value);
        } else if (expr.value.type == typeid(bool)) {
            out_ ~= Op.i32_const;
            leb128s(out_, expr.value.get!bool() ? 1 : 0);
        } else if (expr.value.type == typeid(double)) {
            out_ ~= Op.f64_const;
            double val = expr.value.get!double();
            out_ ~= (cast(ubyte*)&val)[0..8];
        } else if (expr.value.type == typeid(string)) {
            // String literal: emit pointer to Array struct
            string s = expr.value.get!string();
            uint structAddr = emitter.registerArrayLiteral(s);
            out_ ~= Op.i32_const;
            leb128s(out_, structAddr);
        } else {
            throw new EmitError("Unsupported literal type");
        }
    }
    
    void emitIdentifier(ref Appender!(ubyte[]) out_, IdentifierExpression expr) {
        // First check if it's a local variable
        if (auto idx = expr.name in localIndex) {
            out_ ~= Op.local_get;
            leb128u(out_, *idx);
            return;
        }
        
        // Check if it's a struct local - emit address
        if (auto info = expr.name in structLocals) {
            // Emit address: FP + frameOffset
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset);
            out_ ~= Op.i32_add;
            return;
        }
        
        // In a method, check if it's an implicit field access (field without 'this.')
        if (func.structParent !is null) {
            auto field = func.structParent.getField(expr.name);
            if (field) {
                // Implicit this.fieldName - load from this pointer + field offset
                // 'this' is at local index thisLocalIndex (registered in structParams as "this")
                if (auto thisInfo = "this" in structParams) {
                    out_ ~= Op.local_get;
                    leb128u(out_, thisInfo.localIndex);
                    if (field.offset > 0) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    out_ ~= Op.i32_load;
                    out_ ~= cast(ubyte)0x02;  // alignment log2(4)
                    leb128u(out_, 0);          // offset
                    return;
                }
            }
        }
        
        // Check if it's a manifest constant (CTFE-evaluated)
        auto symbol = emitter.symbolTable.lookupSymbol(expr.name);
        if (symbol && symbol.isConstant) {
            if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                if (manifest.ctfeComplete) {
                    if (manifest.isStringType) {
                        // String constant: register and emit struct pointer
                        uint structAddr = emitter.registerArrayLiteral(manifest.ctfeStringValue);
                        out_ ~= Op.i32_const;
                        leb128s(out_, structAddr);
                    } else {
                        // Numeric constant: emit value directly
                        out_ ~= Op.i32_const;
                        leb128s(out_, manifest.ctfeValue);
                    }
                    return;
                }
            }
        }
        
        throw new EmitError("Unknown identifier: " ~ expr.name);
    }
    
    void emitBinary(ref Appender!(ubyte[]) out_, BinaryExpression expr) {
        // Handle string concatenation specially
        if (expr.operator == BinaryExpression.Operator.Concat) {
            emitArrayConcat(out_, expr);
            return;
        }
        
        // Emit operands
        emitExpression(out_, expr.left);
        emitExpression(out_, expr.right);
        
        // Emit operator (assuming i32 for now)
        Op op;
        final switch (expr.operator) {
            case BinaryExpression.Operator.Add: op = Op.i32_add; break;
            case BinaryExpression.Operator.Subtract: op = Op.i32_sub; break;
            case BinaryExpression.Operator.Multiply: op = Op.i32_mul; break;
            case BinaryExpression.Operator.Divide: op = Op.i32_div_s; break;
            case BinaryExpression.Operator.Modulo: op = Op.i32_rem_s; break;
            case BinaryExpression.Operator.Equal: op = Op.i32_eq; break;
            case BinaryExpression.Operator.NotEqual: op = Op.i32_ne; break;
            case BinaryExpression.Operator.Less: op = Op.i32_lt_s; break;
            case BinaryExpression.Operator.LessEqual: op = Op.i32_le_s; break;
            case BinaryExpression.Operator.Greater: op = Op.i32_gt_s; break;
            case BinaryExpression.Operator.GreaterEqual: op = Op.i32_ge_s; break;
            case BinaryExpression.Operator.LogicalAnd:
                // a && b -> a ? b : 0
                // For now, simple: both operands, then and
                op = Op.i32_and;
                break;
            case BinaryExpression.Operator.LogicalOr:
                op = Op.i32_or;
                break;
            case BinaryExpression.Operator.BitwiseAnd: op = Op.i32_and; break;
            case BinaryExpression.Operator.BitwiseOr: op = Op.i32_or; break;
            case BinaryExpression.Operator.BitwiseXor: op = Op.i32_xor; break;
            case BinaryExpression.Operator.ShiftLeft: op = Op.i32_shl; break;
            case BinaryExpression.Operator.ShiftRight: op = Op.i32_shr_s; break;
            case BinaryExpression.Operator.Concat:
                assert(false, "Concat should be handled above");
        }
        out_ ~= op;
    }
    
    void emitArrayConcat(ref Appender!(ubyte[]) out_, BinaryExpression expr) {
        // Emit left operand (pushes array struct pointer)
        emitExpression(out_, expr.left);
        
        // Emit right operand (pushes array struct pointer)
        emitExpression(out_, expr.right);
        
        // Call __array_concat(s1, s2) -> result_ptr
        out_ ~= Op.call;
        leb128u(out_, emitter.concatFuncIndex);
    }
    
    void emitUnary(ref Appender!(ubyte[]) out_, UnaryExpression expr) {
        final switch (expr.operator) {
            case UnaryExpression.Operator.Plus:
                emitExpression(out_, expr.operand);
                break;
                
            case UnaryExpression.Operator.Minus:
                out_ ~= Op.i32_const;
                leb128s(out_, 0);
                emitExpression(out_, expr.operand);
                out_ ~= Op.i32_sub;
                break;
                
            case UnaryExpression.Operator.LogicalNot:
                emitExpression(out_, expr.operand);
                out_ ~= Op.i32_eqz;
                break;
                
            case UnaryExpression.Operator.BitwiseNot:
                emitExpression(out_, expr.operand);
                out_ ~= Op.i32_const;
                leb128s(out_, -1);
                out_ ~= Op.i32_xor;
                break;
                
            case UnaryExpression.Operator.PreIncrement:
            case UnaryExpression.Operator.PostIncrement:
                emitIncDec(out_, expr, true);
                break;
                
            case UnaryExpression.Operator.PreDecrement:
            case UnaryExpression.Operator.PostDecrement:
                emitIncDec(out_, expr, false);
                break;
                
            case UnaryExpression.Operator.AddressOf:
            case UnaryExpression.Operator.Dereference:
                throw new EmitError("Pointer operations not yet supported");
        }
    }
    
    void emitIncDec(ref Appender!(ubyte[]) out_, UnaryExpression expr, bool inc) {
        auto ident = cast(IdentifierExpression)expr.operand;
        if (!ident) {
            throw new EmitError("Increment/decrement requires identifier");
        }
        
        auto idx = localIndex[ident.name];
        
        if (expr.isPostfix) {
            // Return old value, then modify
            out_ ~= Op.local_get;
            leb128u(out_, idx);
            
            out_ ~= Op.local_get;
            leb128u(out_, idx);
            out_ ~= Op.i32_const;
            leb128s(out_, 1);
            out_ ~= (inc ? Op.i32_add : Op.i32_sub);
            out_ ~= Op.local_set;
            leb128u(out_, idx);
        } else {
            // Modify, then return new value
            out_ ~= Op.local_get;
            leb128u(out_, idx);
            out_ ~= Op.i32_const;
            leb128s(out_, 1);
            out_ ~= (inc ? Op.i32_add : Op.i32_sub);
            out_ ~= Op.local_tee;
            leb128u(out_, idx);
        }
    }
    
    void emitCall(ref Appender!(ubyte[]) out_, CallExpression expr) {
        // Handle method calls (obj.method()) - but not UFCS calls
        if (auto memberExpr = cast(MemberExpression)expr.function_) {
            if (expr.isUFCS) {
                // UFCS: obj.func(args...) -> func(obj, args...)
                emitUFCSCall(out_, memberExpr, expr.arguments);
                return;
            }
            emitMethodCall(out_, memberExpr, expr.arguments);
            return;
        }
        
        auto ident = cast(IdentifierExpression)expr.function_;
        if (!ident) {
            throw new EmitError("Indirect calls not yet supported");
        }
        
        // Check if this is struct construction (not a function call)
        auto symbol = emitter.symbolTable.lookupSymbol(ident.name);
        if (symbol && symbol.kind == SymbolKind.Type) {
            if (auto userType = cast(UserType)symbol.type) {
                // Resolve declaration if needed
                if (!userType.declaration) {
                    auto typeSymbol = emitter.symbolTable.lookupSymbol(userType.name);
                    if (typeSymbol && typeSymbol.kind == SymbolKind.Type) {
                        userType.declaration = typeSymbol.declaration;
                    }
                }
                if (auto structDecl = cast(StructDecl)userType.declaration) {
                    // Allocate temp, initialize, return pointer
                    emitStructConstructionToTemp(out_, structDecl, expr.arguments);
                    return;
                }
            }
        }
        
        // Emit arguments (copy structs for pass-by-value semantics)
        uint totalCopySize = 0;
        foreach (arg; expr.arguments) {
            // Check if argument is a struct local that needs copying
            if (auto argIdent = cast(IdentifierExpression)arg) {
                if (auto localInfo = argIdent.name in structLocals) {
                    // Struct local - copy to temp, pass temp address
                    auto structDecl = localInfo.structDecl;
                    uint structSize = cast(uint)structDecl.structSize;
                    
                    // Allocate temp: SP = SP - structSize
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, structSize);
                    out_ ~= Op.i32_sub;
                    out_ ~= Op.global_set;
                    leb128u(out_, emitter.spGlobal);
                    
                    // Copy from FP+offset to SP
                    foreach (field; structDecl.fields) {
                        // Dest: SP + fieldOffset
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        if (field.offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        
                        // Src: FP + srcOffset + fieldOffset
                        out_ ~= Op.local_get;
                        leb128u(out_, fpLocal);
                        out_ ~= Op.i32_const;
                        leb128s(out_, localInfo.frameOffset + cast(int)field.offset);
                        out_ ~= Op.i32_add;
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        
                        // Store
                        out_ ~= Op.i32_store;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                    }
                    
                    // Push SP (address of copy) as argument
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    
                    totalCopySize += structSize;
                    continue;
                }
                
                if (auto paramInfo = argIdent.name in structParams) {
                    // Struct param - already a pointer, copy from it
                    auto structDecl = paramInfo.structDecl;
                    uint structSize = cast(uint)structDecl.structSize;
                    
                    // Allocate temp
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    out_ ~= Op.i32_const;
                    leb128s(out_, structSize);
                    out_ ~= Op.i32_sub;
                    out_ ~= Op.global_set;
                    leb128u(out_, emitter.spGlobal);
                    
                    // Copy from param pointer to SP
                    foreach (field; structDecl.fields) {
                        // Dest: SP + fieldOffset
                        out_ ~= Op.global_get;
                        leb128u(out_, emitter.spGlobal);
                        if (field.offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        
                        // Src: paramPtr + fieldOffset
                        out_ ~= Op.local_get;
                        leb128u(out_, paramInfo.localIndex);
                        if (field.offset > 0) {
                            out_ ~= Op.i32_const;
                            leb128s(out_, cast(int)field.offset);
                            out_ ~= Op.i32_add;
                        }
                        out_ ~= Op.i32_load;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                        
                        // Store
                        out_ ~= Op.i32_store;
                        out_ ~= cast(ubyte)0x02;
                        leb128u(out_, 0);
                    }
                    
                    // Push SP as argument
                    out_ ~= Op.global_get;
                    leb128u(out_, emitter.spGlobal);
                    
                    totalCopySize += structSize;
                    continue;
                }
            }
            
            // Non-struct argument
            emitExpression(out_, arg);
        }
        
        // Call
        uint funcIdx = emitter.getFuncIndex(ident.name);
        out_ ~= Op.call;
        leb128u(out_, funcIdx);
        
        // Restore SP after call (deallocate copies)
        if (totalCopySize > 0) {
            out_ ~= Op.global_get;
            leb128u(out_, emitter.spGlobal);
            out_ ~= Op.i32_const;
            leb128s(out_, totalCopySize);
            out_ ~= Op.i32_add;
            out_ ~= Op.global_set;
            leb128u(out_, emitter.spGlobal);
        }
    }
    
    /**
     * Emit a method call (obj.method(args)).
     * The hidden 'this' pointer is passed as the first argument.
     */
    void emitMethodCall(ref Appender!(ubyte[]) out_, MemberExpression memberExpr, Expression[] args) {
        // Get the struct type from the object
        auto objIdent = cast(IdentifierExpression)memberExpr.object;
        if (!objIdent) {
            throw new EmitError("Method call on non-identifier object not yet supported");
        }
        
        // Find the struct declaration to look up the method
        StructDecl structDecl = null;
        
        // Check if it's a struct local
        if (auto localInfo = objIdent.name in structLocals) {
            structDecl = localInfo.structDecl;
        }
        // Check if it's a struct parameter
        else if (auto paramInfo = objIdent.name in structParams) {
            structDecl = paramInfo.structDecl;
        }
        
        if (!structDecl) {
            throw new EmitError("Cannot determine struct type for method call on " ~ objIdent.name);
        }
        
        // Find the method
        FunctionDecl method = null;
        foreach (member; structDecl.members) {
            if (auto funcDecl = cast(FunctionDecl)member) {
                if (funcDecl.name == memberExpr.memberName && funcDecl.isMethod) {
                    method = funcDecl;
                    break;
                }
            }
        }
        
        if (!method) {
            throw new EmitError("Struct '" ~ structDecl.name ~ "' has no method '" ~ memberExpr.memberName ~ "'");
        }
        
        // Emit 'this' pointer as first argument (address of the struct instance)
        // For a local struct: FP + frameOffset
        // For a param struct: the param value itself (already a pointer)
        if (auto localInfo = objIdent.name in structLocals) {
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, localInfo.frameOffset);
            out_ ~= Op.i32_add;
        } else if (auto paramInfo = objIdent.name in structParams) {
            out_ ~= Op.local_get;
            leb128u(out_, paramInfo.localIndex);
        }
        
        // Emit the other arguments
        foreach (arg; args) {
            emitExpression(out_, arg);
        }
        
        // Generate the mangled method name: StructName_methodName
        string mangledName = structDecl.name ~ "_" ~ method.name;
        
        // Call the method
        uint funcIdx = emitter.getFuncIndex(mangledName);
        out_ ~= Op.call;
        leb128u(out_, funcIdx);
    }
    
    /**
     * Emit a UFCS call (obj.func(args...) -> func(obj, args...)).
     * The object is passed as the first argument to the free function.
     */
    void emitUFCSCall(ref Appender!(ubyte[]) out_, MemberExpression memberExpr, Expression[] args) {
        // Emit the object as the first argument
        emitExpression(out_, memberExpr.object);
        
        // Emit the remaining arguments
        foreach (arg; args) {
            emitExpression(out_, arg);
        }
        
        // Call the free function by name
        uint funcIdx = emitter.getFuncIndex(memberExpr.memberName);
        out_ ~= Op.call;
        leb128u(out_, funcIdx);
    }
    
    /**
     * Emit struct construction to a temporary on shadow stack.
     * Leaves pointer to the struct on the value stack.
     */
    void emitStructConstructionToTemp(ref Appender!(ubyte[]) out_, StructDecl structDecl, Expression[] args) {
        uint structSize = cast(uint)structDecl.structSize;
        
        // Allocate space: SP = SP - structSize
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
        out_ ~= Op.i32_const;
        leb128s(out_, structSize);
        out_ ~= Op.i32_sub;
        out_ ~= Op.global_set;
        leb128u(out_, emitter.spGlobal);
        
        // Initialize at base address = current SP
        emitStructFieldsInit(out_, structDecl, args, EmitAddrMode.fromSP, 0);
        
        // Leave pointer to struct on stack
        out_ ~= Op.global_get;
        leb128u(out_, emitter.spGlobal);
    }
    
    // How to compute the destination address for a field
    enum EmitAddrMode { fromSP, fromFP }
    
    /**
     * Initialize struct fields at a base address.
     * baseMode determines how to compute the address.
     */
    void emitStructFieldsInit(ref Appender!(ubyte[]) out_, StructDecl structDecl, 
                              Expression[] args, EmitAddrMode baseMode, int baseOffset) {
        for (size_t i = 0; i < structDecl.fields.length && i < args.length; i++) {
            auto field = structDecl.fields[i];
            int fieldAddr = baseOffset + cast(int)field.offset;
            
            // Check if argument is nested struct construction
            if (auto callArg = cast(CallExpression)args[i]) {
                if (auto argIdent = cast(IdentifierExpression)callArg.function_) {
                    auto argSymbol = emitter.symbolTable.lookupSymbol(argIdent.name);
                    if (argSymbol && argSymbol.kind == SymbolKind.Type) {
                        if (auto argUserType = cast(UserType)argSymbol.type) {
                            if (!argUserType.declaration) {
                                auto ts = emitter.symbolTable.lookupSymbol(argUserType.name);
                                if (ts) argUserType.declaration = ts.declaration;
                            }
                            if (auto nestedDecl = cast(StructDecl)argUserType.declaration) {
                                // Recurse: initialize nested struct directly at fieldAddr
                                emitStructFieldsInit(out_, nestedDecl, callArg.arguments, 
                                                    baseMode, fieldAddr);
                                continue;
                            }
                        }
                    }
                }
            }
            
            // Emit destination address based on mode
            if (baseMode == EmitAddrMode.fromFP) {
                out_ ~= Op.local_get;
                leb128u(out_, fpLocal);
            } else {
                out_ ~= Op.global_get;
                leb128u(out_, emitter.spGlobal);
            }
            if (fieldAddr != 0) {
                out_ ~= Op.i32_const;
                leb128s(out_, fieldAddr);
                out_ ~= Op.i32_add;
            }
            
            // Emit value
            emitExpression(out_, args[i]);
            
            // Store
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
        }
    }
    
    void emitAssignment(ref Appender!(ubyte[]) out_, AssignmentExpression expr) {
        // Check for struct field assignment (p.x = value)
        if (auto member = cast(MemberExpression)expr.left) {
            emitMemberAssignment(out_, member, expr.right);
            return;
        }
        
        auto ident = cast(IdentifierExpression)expr.left;
        if (!ident) {
            throw new EmitError("Complex assignment targets not yet supported");
        }
        
        // Check for implicit field assignment in a method (fieldName = value)
        if (func.structParent !is null) {
            auto field = func.structParent.getField(ident.name);
            if (field) {
                // Implicit this.fieldName = value
                if (auto thisInfo = "this" in structParams) {
                    // Calculate address: this + fieldOffset
                    out_ ~= Op.local_get;
                    leb128u(out_, thisInfo.localIndex);
                    if (field.offset > 0) {
                        out_ ~= Op.i32_const;
                        leb128s(out_, cast(int)field.offset);
                        out_ ~= Op.i32_add;
                    }
                    
                    // Emit value
                    emitExpression(out_, expr.right);
                    
                    // For consistent semantics, assignment should leave value on stack
                    // Store to temp, emit again for stack value
                    // We need to: [addr, value] -> store, then push value back
                    // Use a temp local to hold the value
                    
                    // Actually, simplest approach: emit value twice (before address)
                    // But we already emitted address. Let's just store and push 0
                    // as a placeholder - the expressionHasValue will need to handle this
                    
                    // Store (consumes addr and value)
                    out_ ~= Op.i32_store;
                    out_ ~= cast(ubyte)0x02;
                    leb128u(out_, 0);
                    
                    // For now, emit value again so assignment has a value
                    // This re-evaluates the expression (not ideal but works for simple cases)
                    emitExpression(out_, expr.right);
                    return;
                }
            }
        }
        
        // Regular local variable assignment
        if (auto idxPtr = ident.name in localIndex) {
            // Emit value
            emitExpression(out_, expr.right);
            
            // Store and leave value on stack (assignment is an expression)
            out_ ~= Op.local_tee;
            leb128u(out_, *idxPtr);
        } else {
            throw new EmitError("Unknown identifier in assignment: " ~ ident.name);
        }
    }
    
    /**
     * Emit assignment to a struct field (p.x = value)
     */
    void emitMemberAssignment(ref Appender!(ubyte[]) out_, MemberExpression member, Expression value) {
        auto objIdent = cast(IdentifierExpression)member.object;
        if (!objIdent) {
            throw new EmitError("Complex member assignment targets not yet supported");
        }
        
        // Check if it's a local struct
        if (auto info = objIdent.name in structLocals) {
            auto structDecl = info.structDecl;
            auto field = structDecl.getField(member.memberName);
            if (!field) {
                throw new EmitError(format("Unknown field '%s' in struct '%s'",
                                          member.memberName, structDecl.name));
            }
            
            // Calculate address: FP + frameOffset + fieldOffset
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset + cast(int)field.offset);
            out_ ~= Op.i32_add;
            
            // Emit value
            emitExpression(out_, value);
            
            // Store (assume i32 for now)
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;  // alignment log2(4)
            leb128u(out_, 0);          // offset
            
            // Assignment is an expression - need to leave value on stack
            // Re-load the value we just stored
            out_ ~= Op.local_get;
            leb128u(out_, fpLocal);
            out_ ~= Op.i32_const;
            leb128s(out_, info.frameOffset + cast(int)field.offset);
            out_ ~= Op.i32_add;
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            return;
        }
        
        // Check if it's a struct parameter
        if (auto info = objIdent.name in structParams) {
            auto structDecl = info.structDecl;
            auto field = structDecl.getField(member.memberName);
            if (!field) {
                throw new EmitError(format("Unknown field '%s' in struct '%s'",
                                          member.memberName, structDecl.name));
            }
            
            // Calculate address: local[paramIdx] + fieldOffset
            out_ ~= Op.local_get;
            leb128u(out_, info.localIndex);
            if (field.offset > 0) {
                out_ ~= Op.i32_const;
                leb128s(out_, cast(int)field.offset);
                out_ ~= Op.i32_add;
            }
            
            // Emit value
            emitExpression(out_, value);
            
            // Store
            out_ ~= Op.i32_store;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            
            // Re-load for expression value
            out_ ~= Op.local_get;
            leb128u(out_, info.localIndex);
            if (field.offset > 0) {
                out_ ~= Op.i32_const;
                leb128s(out_, cast(int)field.offset);
                out_ ~= Op.i32_add;
            }
            out_ ~= Op.i32_load;
            out_ ~= cast(ubyte)0x02;
            leb128u(out_, 0);
            return;
        }
        
        throw new EmitError("Unsupported member assignment target", member.toString());
    }
    
    //==========================================================================
    // Helpers
    //==========================================================================
    
    bool expressionHasValue(Expression expr) {
        // Most expressions produce values
        if (auto call = cast(CallExpression)expr) {
            // Check if function returns void
            auto ident = cast(IdentifierExpression)call.function_;
            if (ident) {
                // Check local functions
                if (auto idx = ident.name in emitter.funcIndex) {
                    auto f = emitter.functions[*idx];
                    auto sig = emitter.types[f.typeIndex];
                    return sig.results.length > 0;
                }
                // Check imported functions
                if (auto idx = ident.name in emitter.importIndex) {
                    auto imp = emitter.imports[*idx];
                    auto sig = emitter.types[imp.typeIndex];
                    return sig.results.length > 0;
                }
            }
            
            // Check for method calls (obj.method())
            if (auto memberExpr = cast(MemberExpression)call.function_) {
                auto objIdent = cast(IdentifierExpression)memberExpr.object;
                if (objIdent) {
                    // Find the struct type
                    StructDecl structDecl = null;
                    if (auto info = objIdent.name in structLocals) {
                        structDecl = info.structDecl;
                    } else if (auto info = objIdent.name in structParams) {
                        structDecl = info.structDecl;
                    }
                    
                    if (structDecl) {
                        // Find the method
                        foreach (member; structDecl.members) {
                            if (auto funcDecl = cast(FunctionDecl)member) {
                                if (funcDecl.name == memberExpr.memberName && funcDecl.isMethod) {
                                    // Check if method returns void
                                    return !isVoidType(funcDecl.returnType);
                                }
                            }
                        }
                    }
                }
            }
            
            return true;  // Assume has value if unknown
        }
        return true;  // Most expressions have values
    }
    
    private bool isVoidType(Type t) {
        if (auto basic = cast(BasicType)t) {
            return basic.kind == BasicType.Kind.Void;
        }
        return false;
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
                    if (manifest.ctfeComplete && !manifest.isStringType) {
                        return manifest.ctfeValue;
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
        // Must be a manifest constant
        auto symbol = emitter.symbolTable.lookupSymbol(expr.name);
        if (symbol && symbol.isConstant) {
            if (auto manifest = cast(ManifestConstantDecl)symbol.declaration) {
                if (manifest.ctfeComplete) {
                    if (manifest.isStringType) {
                        uint structAddr = emitter.registerArrayLiteral(manifest.ctfeStringValue);
                        out_ ~= Op.i32_const;
                        leb128s(out_, structAddr);
                    } else {
                        out_ ~= Op.i32_const;
                        leb128s(out_, manifest.ctfeValue);
                    }
                    return;
                }
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
