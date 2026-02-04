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
            // TODO: return new NativeBackend(symbolTable);
            throw new Exception("Native backend not yet implemented");
        default:
            throw new Exception("Unknown backend: " ~ backendName);
    }
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
