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
        
        // Second pass: collect local functions
        foreach (decl; decls) {
            if (auto funcDecl = cast(FunctionDecl)decl) {
                collectFunction(funcDecl);
            }
            // TODO: globals
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
        return containsOnlyCtfeIntrinsics(decl.body_);
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
        
        // Emit local declarations
        ctx.emitLocalDecls(body_);
        
        // Emit body
        if (f.decl.body_) {
            ctx.emitStatement(body_, f.decl.body_);
        }
        
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
    
    // Block depth for br instructions
    uint blockDepth = 0;
    
    this(FuncInfo f, BinaryEmitter e) {
        this.func = f;
        this.emitter = e;
        
        // Parameters are the first locals
        foreach (i, p; f.decl.parameters) {
            auto vt = e.dTypeToValType(p.type);
            localIndex[p.name] = cast(uint)i;
            localTypes ~= vt;
        }
        paramCount = cast(uint)f.decl.parameters.length;
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
            emitVarDecl(out_, varDecl);
        } else {
            throw new EmitError("Unsupported statement type", stmt.toString());
        }
    }
    
    void emitReturn(ref Appender!(ubyte[]) out_, ReturnStatement stmt) {
        if (stmt.value) {
            emitExpression(out_, stmt.value);
        }
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
        } else {
            throw new EmitError("Unsupported expression type", expr.toString());
        }
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
        auto ident = cast(IdentifierExpression)expr.function_;
        if (!ident) {
            throw new EmitError("Indirect calls not yet supported");
        }
        
        // Emit arguments
        foreach (arg; expr.arguments) {
            emitExpression(out_, arg);
        }
        
        // Call
        uint funcIdx = emitter.getFuncIndex(ident.name);
        out_ ~= Op.call;
        leb128u(out_, funcIdx);
    }
    
    void emitAssignment(ref Appender!(ubyte[]) out_, AssignmentExpression expr) {
        auto ident = cast(IdentifierExpression)expr.left;
        if (!ident) {
            throw new EmitError("Complex assignment targets not yet supported");
        }
        
        auto idx = localIndex[ident.name];
        
        // Emit value
        emitExpression(out_, expr.right);
        
        // Store and leave value on stack (assignment is an expression)
        out_ ~= Op.local_tee;
        leb128u(out_, idx);
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
            return true;  // Assume has value if unknown
        }
        return true;  // Most expressions have values
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
