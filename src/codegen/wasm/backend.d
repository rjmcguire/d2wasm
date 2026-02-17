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
    private SourceLocation lastErrorLoc;
    private bool enableStackTrace;

    this(SymbolTable st, bool enableStackTrace = true) {
        this.symbolTable = st;
        this.enableStackTrace = enableStackTrace;
    }

    override CompiledFunction compile(FunctionDecl func) {
        auto emitter = new BinaryEmitter(symbolTable, enableStackTrace);
        emitter.ctfeMode = true;
        auto wasmBytes = emitter.emit([func]);

        if (wasmBytes is null) {
            lastError = emitter.error();
            lastErrorLoc = emitter.errorLocation();
            return null;
        }

        return new WASMCompiledFunction(func.name, wasmBytes,
            emitter.getArenaBaseValue(), buildNeedsArenaMap([func]));
    }

    override CompiledFunction compileWithDependencies(FunctionDecl[] funcs, string entryFuncName) {
        import std.algorithm : map;
        import std.array : array;

        // Convert FunctionDecl[] to Declaration[] for the emitter
        Declaration[] decls = funcs.map!(f => cast(Declaration)f).array;

        // Include parent struct declarations for method dependencies
        // (emitter needs StructDecl to register methods with mangled names)
        bool[string] addedStructs;
        foreach (f; funcs) {
            if (f.isMethod && f.parent !is null) {
                if (auto sd = cast(StructDecl)f.parent) {
                    if (sd.name !in addedStructs) {
                        decls ~= cast(Declaration)sd;
                        addedStructs[sd.name] = true;
                    }
                }
            }
        }

        auto emitter = new BinaryEmitter(symbolTable, enableStackTrace);
        emitter.ctfeMode = true;
        auto wasmBytes = emitter.emit(decls);

        if (wasmBytes is null) {
            lastError = emitter.error();
            lastErrorLoc = emitter.errorLocation();
            return null;
        }
        version(none) {
            // Debug: dump CTFE WASM module for disassembly
            try {
                import std.file : fwrite = write;
                fwrite("/tmp/ctfe_debug.wasm", wasmBytes);
            } catch (Exception) {}
        }

        return new WASMCompiledFunction(entryFuncName, wasmBytes,
            emitter.getArenaBaseValue(), buildNeedsArenaMap(funcs));
    }

    override ubyte[] compileModule(Declaration[] decls) {
        auto emitter = new BinaryEmitter(symbolTable, enableStackTrace);
        auto result = emitter.emit(decls);
        if (result is null) {
            lastError = emitter.error();
            lastErrorLoc = emitter.errorLocation();
        }
        return result;
    }

    override string error() { return lastError; }
    override SourceLocation errorLocation() { return lastErrorLoc; }
    override string name() { return "wasm"; }

    /// Build a map of function names that have an arena parameter in their signature.
    /// Exported free functions like "main" are excluded — they use the global fallback.
    private static bool[string] buildNeedsArenaMap(FunctionDecl[] funcs) {
        bool[string] result;
        foreach (f; funcs) {
            if (f.needsArena && f.name != "main") {
                if (f.mangledName.length > 0)
                    result[f.mangledName] = true;
                result[f.name] = true;
            }
        }
        return result;
    }
}

/**
 * WASM compiled function - uses wasm3 for execution
 */
class WASMCompiledFunction : CompiledFunction {
    import semantic.ctfe_runtime : CTFERuntime, CTFERuntimeError;

    private string funcName;
    private ubyte[] wasmBytes;
    private CTFERuntime runtime;
    private uint arenaBaseValue;
    private bool[string] needsArenaFuncs;

    this(string name, ubyte[] wasm, uint arenaBase = 0, bool[string] needsArena = null) {
        this.funcName = name;
        this.wasmBytes = wasm;
        this.arenaBaseValue = arenaBase;
        this.needsArenaFuncs = needsArena;
        this.runtime = new CTFERuntime();
        this.runtime.loadModule(wasm);
    }

    override ExecutionResult call(long[] args) {
        try {
            int[] intArgs;
            // Prepend arena if entry function needs it
            if (funcName in needsArenaFuncs)
                intArgs ~= cast(int)arenaBaseValue;
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
            // Prepend arena if target function needs it
            if (targetFuncName in needsArenaFuncs)
                intArgs ~= cast(int)arenaBaseValue;
            foreach (arg; args) {
                intArgs ~= cast(int)arg;
            }

            auto result = runtime.callI32(targetFuncName, intArgs);
            return ExecutionResult.fromInt(result.asInt());

        } catch (CTFERuntimeError e) {
            return ExecutionResult.failure(e.msg);
        }
    }

    override ExecutionResult callWithLargeReturn(string targetFuncName, long[] args, uint resultSize) {
        try {
            // Use a fixed high address for result buffer
            // WASM memory starts at 64KB, use address near the top
            // This is safe for CTFE since we control the memory layout
            uint resultAddr = 65536 - 256 - resultSize;  // Leave some headroom

            // Prepend result address, then arena if needed, then user args
            int[] intArgs;
            intArgs ~= cast(int)resultAddr;
            if (targetFuncName in needsArenaFuncs)
                intArgs ~= cast(int)arenaBaseValue;
            foreach (arg; args) {
                intArgs ~= cast(int)arg;
            }

            // Call function (void return, writes to resultAddr)
            auto result = runtime.callI32(targetFuncName, intArgs);
            // Note: result is void but callI32 still works

            // Read result bytes from memory
            ubyte[] resultBytes = runtime.readMemory(resultAddr, resultSize);

            return ExecutionResult.fromArray(resultBytes);

        } catch (CTFERuntimeError e) {
            return ExecutionResult.failure(e.msg);
        }
    }

    override ubyte[] readMemory(ulong offset, uint length) {
        return runtime.readMemory(cast(uint)offset, length);
    }

    override bool hasFunction(string targetFuncName) {
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
