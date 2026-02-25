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
import std.conv : to;

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
            emitter.getArenaBaseValue(), emitter.exceptionArrayOffset, buildNeedsArenaMap([func]));
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
                if (auto cd = cast(ClassDecl)f.parent) {
                    if (cd.name !in addedStructs) {
                        decls ~= cast(Declaration)cd;
                        addedStructs[cd.name] = true;
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
        version (none) {
            // Debug: dump CTFE WASM module for disassembly
            try {
                import std.file : fwrite = write;
                fwrite("/tmp/ctfe_debug.wasm", wasmBytes);
            } catch (Exception) {}
        }

        return new WASMCompiledFunction(entryFuncName, wasmBytes,
            emitter.getArenaBaseValue(), emitter.exceptionArrayOffset, buildNeedsArenaMap(funcs));
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
    private uint exceptionArrayBase;  // Memory offset of exception slot array
    private bool[string] needsArenaFuncs;

    this(string name, ubyte[] wasm, uint arenaBase = 0, uint excArrayBase = 0, bool[string] needsArena = null) {
        this.funcName = name;
        this.wasmBytes = wasm;
        this.arenaBaseValue = arenaBase;
        this.exceptionArrayBase = excArrayBase;
        this.needsArenaFuncs = needsArena;
        this.runtime = new CTFERuntime();
        this.runtime.loadModule(wasm);
    }

    /// Check for uncaught exception after WASM execution and build failure result.
    /// Reads from the exception slot stack in WASM linear memory.
    private ExecutionResult checkUncaughtException() {
        import codegen.backend : CallStackFrame;
        import codegen.error_kind : ErrorKind, errorKindMessage;
        import codegen.wasm.types : EXCEPTION_SLOT_SIZE, EXCEPTION_SLOT_KIND,
                                    EXCEPTION_SLOT_FILE_OFFSET, EXCEPTION_SLOT_FILE_LEN,
                                    EXCEPTION_SLOT_LINE, EXCEPTION_SLOT_COL, EXCEPTION_SLOT_VALUE;

        int depth = runtime.getGlobalI32("__exception_depth");
        if (depth <= 0) {
            return ExecutionResult.failure("uncaught exception (unknown)");
        }

        // Read the most recent exception slot: slot[depth - 1]
        uint slotAddr = exceptionArrayBase + cast(uint)(depth - 1) * EXCEPTION_SLOT_SIZE;
        uint kind = runtime.readU32(slotAddr + EXCEPTION_SLOT_KIND);
        uint fileOff = runtime.readU32(slotAddr + EXCEPTION_SLOT_FILE_OFFSET);
        uint fileLen = runtime.readU32(slotAddr + EXCEPTION_SLOT_FILE_LEN);
        int line = cast(int)runtime.readU32(slotAddr + EXCEPTION_SLOT_LINE);
        int col = cast(int)runtime.readU32(slotAddr + EXCEPTION_SLOT_COL);
        int value = cast(int)runtime.readU32(slotAddr + EXCEPTION_SLOT_VALUE);

        // Build message from error kind
        string msg = errorKindMessage(cast(ErrorKind)kind);
        if (cast(ErrorKind)kind == ErrorKind.UserThrow) {
            msg ~= " (thrown value: " ~ to!string(value) ~ ")";
        }

        // Read filename from WASM memory
        string errFile;
        try {
            if (fileLen > 0 && fileLen < 1024)
                errFile = runtime.readString(fileOff, fileLen);
        } catch (Exception) {}

        auto r = ExecutionResult.failure(msg, errFile, line, col);

        // Read preserved call stack frames from WASM linear memory
        auto wasmFrames = runtime.getCallStackFrames();
        if (wasmFrames !is null) {
            foreach (f; wasmFrames)
                r.callStack ~= CallStackFrame(f.funcName, f.fileName, f.line, f.column);
        }
        return r;
    }

    /// Build structured failure result from a WASM trap (genuinely unexpected traps).
    /// For div-by-zero and other runtime errors, exceptions now propagate via slots,
    /// so this is only a fallback for genuine wasm3 traps.
    private ExecutionResult buildTrapResult(CTFERuntimeError e) {
        import codegen.backend : CallStackFrame;
        import codegen.error_kind : ErrorKind, errorKindMessage;
        import codegen.wasm.types : EXCEPTION_SLOT_SIZE, EXCEPTION_SLOT_KIND,
                                    EXCEPTION_SLOT_FILE_OFFSET, EXCEPTION_SLOT_FILE_LEN,
                                    EXCEPTION_SLOT_LINE, EXCEPTION_SLOT_COL;
        import std.string : indexOf;

        // Check if there's exception slot data (e.g., overflow guard hit unreachable)
        string errFile;
        int errLine, errCol;
        string msg;

        try {
            int depth = runtime.getGlobalI32("__exception_depth");
            if (depth > 0) {
                uint slotAddr = exceptionArrayBase + cast(uint)(depth - 1) * EXCEPTION_SLOT_SIZE;
                uint kind = runtime.readU32(slotAddr + EXCEPTION_SLOT_KIND);
                uint fileOff = runtime.readU32(slotAddr + EXCEPTION_SLOT_FILE_OFFSET);
                uint fileLen = runtime.readU32(slotAddr + EXCEPTION_SLOT_FILE_LEN);
                errLine = cast(int)runtime.readU32(slotAddr + EXCEPTION_SLOT_LINE);
                errCol = cast(int)runtime.readU32(slotAddr + EXCEPTION_SLOT_COL);
                if (fileLen > 0 && fileLen < 1024)
                    errFile = runtime.readString(fileOff, fileLen);
                msg = errorKindMessage(cast(ErrorKind)kind);
            }
        } catch (Exception) {}

        if (msg.length == 0) {
            // Fallback: extract from wasm3 error message
            msg = e.msg;
            if (msg.length > 0) {
                auto nlIdx = msg.indexOf('\n');
                if (nlIdx >= 0) msg = msg[0..nlIdx];
                enum prefix = "CTFE execution failed: ";
                if (msg.length > prefix.length && msg[0..prefix.length] == prefix)
                    msg = msg[prefix.length..$];
            }
        }

        auto r = ExecutionResult.failure(msg, errFile, errLine, errCol);

        // Read call stack frames
        auto wasmFrames = runtime.getCallStackFrames();
        if (wasmFrames !is null) {
            foreach (f; wasmFrames)
                r.callStack ~= CallStackFrame(f.funcName, f.fileName, f.line, f.column);
        }
        return r;
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
            if (runtime.getGlobalI32("__exception_pending") != 0)
                return checkUncaughtException();
            return ExecutionResult.fromInt(result.asInt());

        } catch (CTFERuntimeError e) {
            return buildTrapResult(e);
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
            if (runtime.getGlobalI32("__exception_pending") != 0)
                return checkUncaughtException();
            return ExecutionResult.fromInt(result.asInt());

        } catch (CTFERuntimeError e) {
            return buildTrapResult(e);
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
            if (runtime.getGlobalI32("__exception_pending") != 0)
                return checkUncaughtException();

            // Read result bytes from memory
            ubyte[] resultBytes = runtime.readMemory(resultAddr, resultSize);

            return ExecutionResult.fromArray(resultBytes);

        } catch (CTFERuntimeError e) {
            return buildTrapResult(e);
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
