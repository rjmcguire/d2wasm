/**
 * Backend Interface for Code Generation
 * 
 * This module defines the abstract interface that all code generation backends
 * must implement. This allows swapping between WASM and Native backends.
 * 
 * The key abstraction is at the function compilation level:
 * - Compile a function declaration to executable form
 * - Execute the compiled function with arguments
 * - Clean up resources when done
 */
module codegen.backend;

import ast.nodes;
import ast.expressions;
import semantic.symbol_table;

/**
 * Result of compiling and executing a function
 */
struct ExecutionResult {
    bool success;
    long intValue;
    string stringValue;
    ubyte[] arrayBytes;
    string error;
    
    static ExecutionResult fromInt(long v) {
        return ExecutionResult(true, v, null, null, null);
    }
    
    static ExecutionResult fromString(string s) {
        return ExecutionResult(true, 0, s, null, null);
    }
    
    static ExecutionResult fromArray(ubyte[] bytes) {
        return ExecutionResult(true, 0, null, bytes, null);
    }
    
    static ExecutionResult failure(string err) {
        return ExecutionResult(false, 0, null, null, err);
    }
}

/**
 * A compiled function that can be executed.
 * 
 * Backends return this from compile(), and the caller can invoke it
 * multiple times with different arguments before disposing.
 */
interface CompiledFunction {
    /// Execute the function with the given arguments
    ExecutionResult call(long[] args);
    
    /// Release any resources (native memory, runtime state, etc.)
    void dispose();
    
    /// Get the function name (for debugging)
    string name();
}

/**
 * Abstract backend for code generation.
 * 
 * Implementations:
 * - WASMBackend: Compiles to WASM, executes via wasm3
 * - NativeBackend: Compiles to ARM64, executes directly
 */
interface Backend {
    /**
     * Compile a single function to executable form.
     * 
     * The returned CompiledFunction can be called multiple times.
     * Caller is responsible for calling dispose() when done.
     */
    CompiledFunction compile(FunctionDecl func);
    
    /**
     * Compile multiple declarations (for full module compilation).
     * Returns raw bytes (WASM binary or native object, depending on backend).
     * Returns null on failure.
     */
    ubyte[] compileModule(Declaration[] decls);
    
    /**
     * Get the last error message, if any.
     */
    string error();
    
    /**
     * Backend name for debugging/logging.
     */
    string name();
}

/**
 * Backend factory - creates the appropriate backend based on configuration.
 */
Backend createBackend(string backendName, SymbolTable symbolTable) {
    switch (backendName) {
        case "wasm":
            return new WASMBackend(symbolTable);
        case "native":
            return new NativeBackend(symbolTable);
        default:
            throw new Exception("Unknown backend: " ~ backendName);
    }
}

/**
 * Native Backend - compiles to ARM64 machine code via copy-and-patch
 */
class NativeBackend : Backend {
    import codegen.native.arm64_codegen;
    import codegen.native.stencil_table;
    import semantic.type_checker;
    
    private SymbolTable symbolTable;
    private string lastError;
    
    this(SymbolTable st) {
        this.symbolTable = st;
    }
    
    override CompiledFunction compile(FunctionDecl func) {
        // Type-check first
        auto typeChecker = new TypeChecker(symbolTable);
        try {
            typeChecker.checkFunctionDeclaration(func);
        } catch (Exception e) {
            lastError = "Type check error: " ~ e.msg;
            return null;
        }
        
        try {
            return new NativeCompiledFunction(func, symbolTable);
        } catch (Exception e) {
            lastError = "Native compile error: " ~ e.msg;
            return null;
        }
    }
    
    override ubyte[] compileModule(Declaration[] decls) {
        // Native backend doesn't produce portable binary output (yet)
        // For now, only supports single-function CTFE compilation
        lastError = "Native backend does not support module compilation";
        return null;
    }
    
    override string error() { return lastError; }
    override string name() { return "native"; }
}

/**
 * Native compiled function - executes ARM64 code directly
 */
class NativeCompiledFunction : CompiledFunction {
    import codegen.native.arm64_codegen;
    import codegen.native.stencil_table;
    import ast.nodes;
    import ast.statements;
    import ast.expressions;
    
    private string funcName;
    private NativeCodeGen gen;  // renamed from codegen to avoid module name collision
    private size_t entryPoint;
    
    this(FunctionDecl func, SymbolTable symbolTable) {
        import std.stdio : writeln;
        
        this.funcName = func.name;
        this.gen = NativeCodeGen.alloc(64 * 1024);  // 64KB code buffer
        
        if (!gen.base) {
            throw new Exception("Failed to allocate executable memory");
        }
        
        // Compile the function
        compileFunction(func);
        
        // Finalize (resolve branches, make executable)
        if (!gen.finalize()) {
            throw new Exception("Failed to finalize native code");
        }
    }
    
    private void compileFunction(FunctionDecl func) {
        import std.stdio : writeln;
        
        entryPoint = gen.pos;
        
        // Count locals needed
        uint localBytes = countLocals(func) * 8;  // 8 bytes per local
        
        // Emit prologue
        if (localBytes > 0) {
            gen.emitPrologueWithLocals(localBytes);
        } else {
            gen.emitPrologue();
        }
        
        // Compile body
        if (func.body_) {
            compileStatement(func.body_);
        }
        
        // Emit epilogue (if not already returned)
        if (localBytes > 0) {
            gen.emitEpilogueWithLocals(localBytes);
        } else {
            gen.emitEpilogue();
        }
    }
    
    private uint countLocals(FunctionDecl func) {
        // For now, simple counting - no actual local management
        return 0;
    }
    
    private void compileStatement(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements) {
                compileStatement(s);
            }
        } else if (auto ret = cast(ReturnStatement)stmt) {
            if (ret.value) {
                compileExpression(ret.value);
            }
            // Return value is in x0, epilogue will handle the rest
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            compileExpression(exprStmt.expression);
        }
        // TODO: if, while, for, var decls
    }
    
    private void compileExpression(Expression expr) {
        import std.variant : Variant;
        
        if (auto lit = cast(LiteralExpression)expr) {
            // Handle different literal types via Variant
            if (lit.value.type == typeid(long)) {
                gen.emitImm32(stencil_load_imm32, cast(int)lit.value.get!long);
            } else if (lit.value.type == typeid(int)) {
                gen.emitImm32(stencil_load_imm32, lit.value.get!int);
            } else if (lit.value.type == typeid(bool)) {
                gen.emitImm32(stencil_load_imm32, lit.value.get!bool ? 1 : 0);
            } else {
                throw new Exception("Literal type not supported: " ~ lit.value.type.toString());
            }
        } else if (auto binOp = cast(BinaryExpression)expr) {
            // Compile right operand first (into x0)
            compileExpression(binOp.right);
            gen.emitMoveX0ToX1();  // Move to x1
            // Compile left operand (into x0)
            compileExpression(binOp.left);
            // Now x0=left, x1=right
            
            // Emit operation
            final switch (binOp.operator) {
                case BinaryExpression.Operator.Add:
                    gen.emit(stencil_add_i32);
                    break;
                case BinaryExpression.Operator.Subtract:
                    gen.emit(stencil_sub_i32);
                    break;
                case BinaryExpression.Operator.Multiply:
                    gen.emit(stencil_mul_i32);
                    break;
                case BinaryExpression.Operator.Divide:
                    gen.emit(stencil_div_i32);
                    break;
                case BinaryExpression.Operator.Modulo:
                    gen.emit(stencil_mod_i32);
                    break;
                case BinaryExpression.Operator.Equal:
                    gen.emit(stencil_eq_i32);
                    break;
                case BinaryExpression.Operator.NotEqual:
                    gen.emit(stencil_ne_i32);
                    break;
                case BinaryExpression.Operator.Less:
                    gen.emit(stencil_lt_i32);
                    break;
                case BinaryExpression.Operator.LessEqual:
                    gen.emit(stencil_le_i32);
                    break;
                case BinaryExpression.Operator.Greater:
                    gen.emit(stencil_gt_i32);
                    break;
                case BinaryExpression.Operator.GreaterEqual:
                    gen.emit(stencil_ge_i32);
                    break;
                case BinaryExpression.Operator.BitwiseAnd:
                    gen.emit(stencil_and_i32);
                    break;
                case BinaryExpression.Operator.BitwiseOr:
                    gen.emit(stencil_or_i32);
                    break;
                case BinaryExpression.Operator.BitwiseXor:
                    gen.emit(stencil_xor_i32);
                    break;
                case BinaryExpression.Operator.ShiftLeft:
                    gen.emit(stencil_shl_i32);
                    break;
                case BinaryExpression.Operator.ShiftRight:
                    gen.emit(stencil_shr_i32);
                    break;
                case BinaryExpression.Operator.LogicalAnd:
                case BinaryExpression.Operator.LogicalOr:
                case BinaryExpression.Operator.Concat:
                    throw new Exception("Operator not yet supported in native backend");
            }
        } else if (auto unaryOp = cast(UnaryExpression)expr) {
            compileExpression(unaryOp.operand);
            if (unaryOp.operator == UnaryExpression.Operator.Minus) {
                // 0 - x
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, 0);
                gen.emit(stencil_sub_i32);
            } else if (unaryOp.operator == UnaryExpression.Operator.LogicalNot) {
                // x == 0
                gen.emitMoveX0ToX1();
                gen.emitImm32(stencil_load_imm32, 0);
                gen.emit(stencil_eq_i32);
            }
        } else {
            throw new Exception("Expression type not yet supported in native backend: " ~ 
                typeid(expr).toString());
        }
    }
    
    override ExecutionResult call(long[] args) {
        // Get function pointer to entry point
        alias FuncType = extern(C) long function();
        auto fn = cast(FuncType)(gen.base + entryPoint);
        
        // Call it! (args not yet supported)
        long result = fn();
        
        return ExecutionResult.fromInt(result);
    }
    
    override void dispose() {
        if (gen.base) {
            gen.free();
        }
    }
    
    override string name() { return funcName; }
}

/**
 * WASM Backend - wraps the existing BinaryEmitter and CTFERuntime
 */
class WASMBackend : Backend {
    import codegen.emitter : BinaryEmitter;
    
    private SymbolTable symbolTable;
    private string lastError;
    
    this(SymbolTable st) {
        this.symbolTable = st;
    }
    
    override CompiledFunction compile(FunctionDecl func) {
        auto emitter = new BinaryEmitter(symbolTable);
        auto wasmBytes = emitter.emit([func]);
        
        if (wasmBytes is null) {
            lastError = emitter.error();
            return null;
        }
        
        return new WASMCompiledFunction(func.name, wasmBytes);
    }
    
    override ubyte[] compileModule(Declaration[] decls) {
        auto emitter = new BinaryEmitter(symbolTable);
        auto result = emitter.emit(decls);
        if (result is null) {
            lastError = emitter.error();
        }
        return result;
    }
    
    override string error() { return lastError; }
    override string name() { return "wasm"; }
}

/**
 * WASM compiled function - uses wasm3 for execution
 */
class WASMCompiledFunction : CompiledFunction {
    import semantic.ctfe_runtime : CTFERuntime, CTFERuntimeError;
    
    private string funcName;
    private ubyte[] wasmBytes;
    private CTFERuntime runtime;
    
    this(string name, ubyte[] wasm) {
        this.funcName = name;
        this.wasmBytes = wasm;
        this.runtime = new CTFERuntime();
        this.runtime.loadModule(wasm);
    }
    
    override ExecutionResult call(long[] args) {
        try {
            int[] intArgs;
            foreach (arg; args) {
                intArgs ~= cast(int)arg;
            }
            
            auto result = runtime.callI32(funcName, intArgs);
            return ExecutionResult.fromInt(result.asInt());
            
        } catch (CTFERuntimeError e) {
            return ExecutionResult.failure(e.msg);
        }
    }
    
    override void dispose() {
        if (runtime) {
            destroy(runtime);
            runtime = null;
        }
    }
    
    override string name() { return funcName; }
}
