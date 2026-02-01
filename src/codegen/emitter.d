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
 *   7. Data    - Emit data section (string literals, etc.)
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
        
        // State
        EmitPhase phase = EmitPhase.init;
        string lastError;
        
        // Symbol table for lookups
        SymbolTable symbolTable;
        
        // Memory tracking
        bool needsMemory = false;
        uint memoryPages = 1;
        
        // Data section
        struct DataEntry {
            uint offset;
            ubyte[] data;
        }
        DataEntry[] dataEntries;
        uint nextDataOffset = 16;  // Start after iovec space
    }
    
    this(SymbolTable symbolTable) {
        this.symbolTable = symbolTable;
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
            
            phase = EmitPhase.init;
            emitHeader();
            
            phase = EmitPhase.emittingTypes;
            emitTypeSection();
            
            phase = EmitPhase.emittingFunctions;
            emitFunctionSection();
            
            phase = EmitPhase.emittingMemory;
            emitMemorySection();
            
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
    // Phase 0: Collection
    //==========================================================================
    
    private void collect(Declaration[] decls) {
        foreach (decl; decls) {
            if (auto funcDecl = cast(FunctionDecl)decl) {
                collectFunction(funcDecl);
            }
            // TODO: globals, imports
        }
    }
    
    private void collectFunction(FunctionDecl decl) {
        // Skip CTFE-only functions (those containing CTFE intrinsics like __writeln)
        if (isCtfeOnlyFunction(decl)) {
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
    // Export Section
    //==========================================================================
    
    private void emitExportSection() {
        Appender!(ubyte[]) section;
        
        // Count exports (functions + memory)
        uint exportCount = 0;
        foreach (f; functions) {
            if (f.exported) exportCount++;
        }
        exportCount++;  // Memory export
        
        leb128u(section, exportCount);
        
        // Export functions
        foreach (i, f; functions) {
            if (!f.exported) continue;
            
            // Name
            leb128u(section, f.name.length);
            section ~= cast(ubyte[])f.name;
            
            // Kind: function
            section ~= cast(ubyte)ExportKind.func;
            
            // Index
            leb128u(section, i);
        }
        
        // Export memory
        {
            string memName = "memory";
            leb128u(section, memName.length);
            section ~= cast(ubyte[])memName;
            section ~= cast(ubyte)ExportKind.memory;
            leb128u(section, 0);  // Memory index 0
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
     */
    uint getFuncIndex(string name) {
        if (auto idx = name in funcIndex) {
            return *idx;
        }
        throw new EmitError("Unknown function: " ~ name);
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
            out_ ~= Op.i32_const;
            leb128s(out_, expr.value.get!long());
        } else if (expr.value.type == typeid(bool)) {
            out_ ~= Op.i32_const;
            leb128s(out_, expr.value.get!bool() ? 1 : 0);
        } else if (expr.value.type == typeid(double)) {
            out_ ~= Op.f64_const;
            double val = expr.value.get!double();
            out_ ~= (cast(ubyte*)&val)[0..8];
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
                    // Emit the CTFE-evaluated value directly
                    out_ ~= Op.i32_const;
                    leb128s(out_, manifest.ctfeValue);
                    return;
                }
            }
        }
        
        throw new EmitError("Unknown identifier: " ~ expr.name);
    }
    
    void emitBinary(ref Appender!(ubyte[]) out_, BinaryExpression expr) {
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
                throw new EmitError("String concatenation not supported in runtime code (use CTFE)");
        }
        out_ ~= op;
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
                if (auto idx = ident.name in emitter.funcIndex) {
                    auto f = emitter.functions[*idx];
                    auto sig = emitter.types[f.typeIndex];
                    return sig.results.length > 0;
                }
            }
            return true;  // Assume has value if unknown
        }
        return true;  // Most expressions have values
    }
}
