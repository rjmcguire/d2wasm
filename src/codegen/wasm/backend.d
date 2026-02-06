/**
 * WASM Backend Implementation
 * 
 * Implements the Backend interface for WebAssembly target.
 * Uses BinaryEmitter for code generation and wasm3 (via CTFERuntime) for execution.
 */
module codegen.wasm.backend;

import codegen.backend : Backend, CompiledFunction, ExecutionResult;
import codegen.emitter : BinaryEmitter;
import ast.nodes;
import semantic.symbol_table;

/**
 * WASM Backend - compiles to WebAssembly, executes via wasm3
 */
class WASMBackend : Backend {
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
    
    override CompiledFunction compileWithDependencies(FunctionDecl[] funcs, string entryFuncName) {
        import std.algorithm : map;
        import std.array : array;
        
        // Convert FunctionDecl[] to Declaration[] for the emitter
        Declaration[] decls = funcs.map!(f => cast(Declaration)f).array;
        
        auto emitter = new BinaryEmitter(symbolTable);
        auto wasmBytes = emitter.emit(decls);
        
        if (wasmBytes is null) {
            lastError = emitter.error();
            return null;
        }
        
        return new WASMCompiledFunction(entryFuncName, wasmBytes);
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
    
    override ExecutionResult callByName(string targetFuncName, long[] args) {
        try {
            int[] intArgs;
            foreach (arg; args) {
                intArgs ~= cast(int)arg;
            }
            
            auto result = runtime.callI32(targetFuncName, intArgs);
            return ExecutionResult.fromInt(result.asInt());
            
        } catch (CTFERuntimeError e) {
            return ExecutionResult.failure(e.msg);
        }
    }
    
    override bool hasFunction(string targetFuncName) {
        // WASM runtime exports all functions, so any compiled function should be callable
        // For a proper implementation, we'd check the module exports
        // For now, assume true (will fail at call time if not found)
        return true;
    }
    
    override void dispose() {
        if (runtime) {
            destroy(runtime);
            runtime = null;
        }
    }
    
    override string name() { return funcName; }
}
