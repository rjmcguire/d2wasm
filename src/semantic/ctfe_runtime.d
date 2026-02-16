/**
 * CTFE Runtime - Live WASM Memory Execution
 * 
 * This module provides a runtime for CTFE that uses wasm3 as a library.
 * The key insight: WASM linear memory during CTFE is "live" - we can
 * read from it, write to it, and extract values after execution.
 */
module semantic.ctfe_runtime;

import wasm3.binding.binding;
import std.stdio;
import std.string;
import std.conv;
import std.format;

/**
 * Type tag for CTFE values
 */
enum CTFEType {
    void_,
    i32,
    i64,
    f32,
    f64,
    string_,
    array_,
}

/**
 * A value that exists in CTFE memory.
 */
struct CTFEValue {
    CTFEType type;
    
    // Scalar values
    union {
        int i32Val;
        long i64Val;
        float f32Val;
        double f64Val;
    }
    
    // Reference type data
    uint ptr;
    uint len;
    ubyte[] bytes;  // Extracted from WASM memory
    
    static CTFEValue fromI32(int v) {
        CTFEValue val;
        val.type = CTFEType.i32;
        val.i32Val = v;
        return val;
    }
    
    static CTFEValue fromI64(long v) {
        CTFEValue val;
        val.type = CTFEType.i64;
        val.i64Val = v;
        return val;
    }
    
    static CTFEValue fromString(uint ptr, uint len, ubyte[] data) {
        CTFEValue val;
        val.type = CTFEType.string_;
        val.ptr = ptr;
        val.len = len;
        val.bytes = data;
        return val;
    }
    
    static CTFEValue fromStringDirect(string s) {
        CTFEValue val;
        val.type = CTFEType.string_;
        val.ptr = 0;
        val.len = cast(uint)s.length;
        val.bytes = cast(ubyte[])s.dup;
        return val;
    }
    
    static CTFEValue void_() {
        CTFEValue val;
        val.type = CTFEType.void_;
        return val;
    }
    
    string asString() const {
        if (type != CTFEType.string_) {
            throw new Exception("CTFEValue is not a string");
        }
        return cast(string)bytes.idup;
    }
    
    int asInt() const {
        if (type != CTFEType.i32) {
            throw new Exception("CTFEValue is not an i32");
        }
        return i32Val;
    }
    
    long asLong() const {
        if (type == CTFEType.i32) return i32Val;
        if (type == CTFEType.i64) return i64Val;
        throw new Exception("CTFEValue is not an integer");
    }
    
    string toString() const {
        final switch (type) {
            case CTFEType.void_: return "void";
            case CTFEType.i32: return format("i32(%d)", i32Val);
            case CTFEType.i64: return format("i64(%d)", i64Val);
            case CTFEType.f32: return format("f32(%f)", f32Val);
            case CTFEType.f64: return format("f64(%f)", f64Val);
            case CTFEType.string_: return format("string(\"%s\")", cast(string)bytes);
            case CTFEType.array_: return format("array(%d bytes)", len);
        }
    }
}

//==============================================================================
// CTFE Host Functions
// These are called from WASM via imports from the "ctfe" module
//==============================================================================

// Store runtime reference for host functions that need memory access
private __gshared IM3Runtime g_ctfeRuntime;

/**
 * Host implementation of __ctfe_print_i32
 * Standalone debug print - prints "CTFE: <value>\n"
 */
extern(C) const(void)* hostPrintI32(IM3Runtime runtime, IM3ImportContext ctx, uint* stack, void* mem) {
    int value = cast(int)(*stack);
    writeln("CTFE: ", value);
    return null;  // No error
}

/**
 * Host implementation of __ctfe_write_i32
 * Building block for __writeln - just the value, no prefix, no newline.
 */
extern(C) const(void)* hostWriteI32(IM3Runtime runtime, IM3ImportContext ctx, uint* stack, void* mem) {
    int value = cast(int)(*stack);
    write(value);
    return null;
}

/**
 * Host implementation of __ctfe_write_str
 * Building block for __writeln - string from WASM memory (ptr, len).
 */
extern(C) const(void)* hostWriteStr(IM3Runtime runtime, IM3ImportContext ctx, uint* stack, void* mem) {
    // wasm3 raw stack uses 64-bit slots per argument
    // stack[0], stack[1] = first arg (ptr) as 64-bit
    // stack[2], stack[3] = second arg (len) as 64-bit
    uint ptr = stack[0];
    uint len = stack[2];
    
    // Get memory pointer
    uint memSize;
    ubyte* wasmMem = m3_GetMemory(runtime, &memSize, 0);
    
    if (wasmMem is null || ptr + len > memSize) {
        return "CTFE: memory access out of bounds".ptr;
    }
    
    auto str = cast(char[])wasmMem[ptr .. ptr + len];
    write(str);
    return null;
}

/**
 * Host implementation of __ctfe_write_bool
 * Building block for __writeln - prints "true" or "false".
 */
extern(C) const(void)* hostWriteBool(IM3Runtime runtime, IM3ImportContext ctx, uint* stack, void* mem) {
    int value = cast(int)(*stack);
    write(value != 0 ? "true" : "false");
    return null;
}

/**
 * Host implementation of __ctfe_write_newline
 * Building block for __writeln - just a newline.
 */
extern(C) const(void)* hostWriteNewline(IM3Runtime runtime, IM3ImportContext ctx, uint* stack, void* mem) {
    writeln();
    return null;
}

// ---- __ctfe_runtime host functions ----
// Arena state for __ctfe_runtime.alloc/push/pop/remaining.
// Reset on each loadModule() call. Single-threaded, non-reentrant.
private __gshared uint g_arenaOffset = 2048;     // First 2KB reserved (MEMORY_RESERVED)
private __gshared uint[] g_arenaSaveStack;

/**
 * __ctfe_runtime.alloc(size) → pointer
 * 8-byte aligned bump allocator in WASM linear memory.
 */
extern(C) const(void)* hostCtfeRuntimeAlloc(IM3Runtime runtime, IM3ImportContext ctx, uint* stack, void* mem) {
    uint size = stack[0];
    // 8-byte align
    uint aligned = (g_arenaOffset + 7) & ~7;
    g_arenaOffset = aligned + size;
    // Return pointer via stack[0] (wasm3 convention for return values)
    stack[0] = aligned;
    return null;
}

/**
 * __ctfe_runtime.push() → void
 * Save current watermark for later restore.
 */
extern(C) const(void)* hostCtfeRuntimePush(IM3Runtime runtime, IM3ImportContext ctx, uint* stack, void* mem) {
    g_arenaSaveStack ~= g_arenaOffset;
    return null;
}

/**
 * __ctfe_runtime.pop() → void
 * Restore watermark from last push.
 */
extern(C) const(void)* hostCtfeRuntimePop(IM3Runtime runtime, IM3ImportContext ctx, uint* stack, void* mem) {
    if (g_arenaSaveStack.length == 0) {
        return "CTFE: Arena pop without matching push".ptr;
    }
    g_arenaOffset = g_arenaSaveStack[$ - 1];
    g_arenaSaveStack = g_arenaSaveStack[0 .. $ - 1];
    return null;
}

/**
 * __ctfe_runtime.remaining() → int
 * Returns available bytes in the 64KB WASM memory.
 */
extern(C) const(void)* hostCtfeRuntimeRemaining(IM3Runtime runtime, IM3ImportContext ctx, uint* stack, void* mem) {
    enum MEMORY_SIZE = 64 * 1024;
    stack[0] = MEMORY_SIZE - g_arenaOffset;
    return null;
}

/**
 * CTFE Runtime Error
 */
class CTFERuntimeError : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

/**
 * CTFE Runtime - executes WASM with live memory access
 */
class CTFERuntime {
    private {
        IM3Environment env;
        IM3Runtime runtime;
        IM3Module mod;
        bool initialized = false;
    }
    
    this() {
        env = m3_NewEnvironment();
        if (env is null) {
            throw new CTFERuntimeError("Failed to create wasm3 environment");
        }
    }
    
    ~this() {
        if (runtime !is null) {
            m3_FreeRuntime(runtime);
        }
        if (env !is null) {
            m3_FreeEnvironment(env);
        }
    }
    
    /**
     * Load a WASM module
     */
    void loadModule(const(ubyte)[] wasmBytes) {
        // Create runtime with 64KB stack
        runtime = m3_NewRuntime(env, 64 * 1024, null);
        if (runtime is null) {
            throw new CTFERuntimeError("Failed to create wasm3 runtime");
        }
        
        // Parse module
        auto result = m3_ParseModule(env, &mod, cast(ubyte*)wasmBytes.ptr, cast(uint)wasmBytes.length);
        if (result !is null) {
            throw new CTFERuntimeError("Failed to parse WASM: " ~ fromStringz(result).idup);
        }
        
        // Load module into runtime
        result = m3_LoadModule(runtime, mod);
        if (result !is null) {
            throw new CTFERuntimeError("Failed to load WASM: " ~ fromStringz(result).idup);
        }
        
        // Reset __ctfe_runtime arena state for each new module
        g_arenaOffset = 2048;
        g_arenaSaveStack = [];

        // Link CTFE host functions
        linkCTFEHostFunctions();

        initialized = true;
    }
    
    /**
     * Link host functions for CTFE intrinsics.
     * These are called from WASM via imports from the "ctfe" module.
     */
    private void linkCTFEHostFunctions() {
        const(char)* result;
        
        // Standalone debug function
        // __ctfe_print_i32: prints "CTFE: <value>\n"
        result = m3_LinkRawFunction(mod, "ctfe".ptr, "__ctfe_print_i32".ptr, "v(i)".ptr, &hostPrintI32);
        if (result !is null && result != m3Err_functionLookupFailed) {
            throw new CTFERuntimeError("Failed to link __ctfe_print_i32: " ~ fromStringz(result).idup);
        }
        
        // Building blocks for __writeln (no prefix, no automatic newline)
        // __ctfe_write_i32: just the value
        result = m3_LinkRawFunction(mod, "ctfe".ptr, "__ctfe_write_i32".ptr, "v(i)".ptr, &hostWriteI32);
        if (result !is null && result != m3Err_functionLookupFailed) {
            throw new CTFERuntimeError("Failed to link __ctfe_write_i32: " ~ fromStringz(result).idup);
        }
        
        // __ctfe_write_str: void(ptr, len)
        result = m3_LinkRawFunction(mod, "ctfe".ptr, "__ctfe_write_str".ptr, "v(ii)".ptr, &hostWriteStr);
        if (result !is null && result != m3Err_functionLookupFailed) {
            throw new CTFERuntimeError("Failed to link __ctfe_write_str: " ~ fromStringz(result).idup);
        }
        
        // __ctfe_write_bool: void(i32)
        result = m3_LinkRawFunction(mod, "ctfe".ptr, "__ctfe_write_bool".ptr, "v(i)".ptr, &hostWriteBool);
        if (result !is null && result != m3Err_functionLookupFailed) {
            throw new CTFERuntimeError("Failed to link __ctfe_write_bool: " ~ fromStringz(result).idup);
        }
        
        // __ctfe_write_newline: void()
        result = m3_LinkRawFunction(mod, "ctfe".ptr, "__ctfe_write_newline".ptr, "v()".ptr, &hostWriteNewline);
        if (result !is null && result != m3Err_functionLookupFailed) {
            throw new CTFERuntimeError("Failed to link __ctfe_write_newline: " ~ fromStringz(result).idup);
        }

        // __ctfe_runtime host functions (arena management)
        result = m3_LinkRawFunction(mod, "ctfe".ptr, "__ctfe_runtime_alloc".ptr, "i(i)".ptr, &hostCtfeRuntimeAlloc);
        if (result !is null && result != m3Err_functionLookupFailed) {
            throw new CTFERuntimeError("Failed to link __ctfe_runtime_alloc: " ~ fromStringz(result).idup);
        }
        result = m3_LinkRawFunction(mod, "ctfe".ptr, "__ctfe_runtime_push".ptr, "v()".ptr, &hostCtfeRuntimePush);
        if (result !is null && result != m3Err_functionLookupFailed) {
            throw new CTFERuntimeError("Failed to link __ctfe_runtime_push: " ~ fromStringz(result).idup);
        }
        result = m3_LinkRawFunction(mod, "ctfe".ptr, "__ctfe_runtime_pop".ptr, "v()".ptr, &hostCtfeRuntimePop);
        if (result !is null && result != m3Err_functionLookupFailed) {
            throw new CTFERuntimeError("Failed to link __ctfe_runtime_pop: " ~ fromStringz(result).idup);
        }
        result = m3_LinkRawFunction(mod, "ctfe".ptr, "__ctfe_runtime_remaining".ptr, "i()".ptr, &hostCtfeRuntimeRemaining);
        if (result !is null && result != m3Err_functionLookupFailed) {
            throw new CTFERuntimeError("Failed to link __ctfe_runtime_remaining: " ~ fromStringz(result).idup);
        }
    }
    
    /**
     * Call a function that returns i32
     */
    CTFEValue callI32(string funcName, int[] args...) {
        if (!initialized) {
            throw new CTFERuntimeError("Runtime not initialized");
        }
        
        IM3Function func;
        auto result = m3_FindFunction(&func, runtime, funcName.toStringz());
        if (result !is null) {
            throw new CTFERuntimeError("Function not found: " ~ funcName ~ " - " ~ fromStringz(result).idup);
        }
        
        // Call function
        if (args.length == 0) {
            result = m3_CallV(func);
        } else if (args.length == 1) {
            result = m3_CallV(func, args[0]);
        } else if (args.length == 2) {
            result = m3_CallV(func, args[0], args[1]);
        } else if (args.length == 3) {
            result = m3_CallV(func, args[0], args[1], args[2]);
        } else {
            throw new CTFERuntimeError("Too many arguments (max 3 for now)");
        }
        
        if (result !is null) {
            string baseError = "CTFE execution failed: " ~ fromStringz(result).idup;
            throw new CTFERuntimeError(formatErrorWithStack(baseError));
        }
        
        // Get return value from stack
        // wasm3 leaves the result at runtime.stack
        int returnValue;
        auto getResult = m3_GetResultsV(func, &returnValue);
        if (getResult !is null) {
            // No result is OK for some functions
        }
        
        return CTFEValue.fromI32(returnValue);
    }
    
    /**
     * Call a void function
     */
    CTFEValue callVoid(string funcName) {
        if (!initialized) {
            throw new CTFERuntimeError("Runtime not initialized");
        }
        
        IM3Function func;
        auto result = m3_FindFunction(&func, runtime, funcName.toStringz());
        if (result !is null) {
            throw new CTFERuntimeError("Function not found: " ~ funcName);
        }
        
        result = m3_CallV(func);
        if (result !is null) {
            string baseError = "CTFE execution failed: " ~ fromStringz(result).idup;
            throw new CTFERuntimeError(formatErrorWithStack(baseError));
        }
        
        return CTFEValue.void_();
    }
    
    /**
     * Read bytes from WASM linear memory
     */
    ubyte[] readMemory(uint offset, uint length) {
        if (!initialized) {
            throw new CTFERuntimeError("Runtime not initialized");
        }
        
        uint memSize;
        ubyte* mem = m3_GetMemory(runtime, &memSize, 0);
        
        if (mem is null) {
            throw new CTFERuntimeError("No memory in WASM module");
        }
        
        if (offset + length > memSize) {
            throw new CTFERuntimeError(format("Memory access out of bounds: %d + %d > %d", 
                                              offset, length, memSize));
        }
        
        return mem[offset .. offset + length].dup;
    }
    
    /**
     * Read a string from memory (given ptr and len)
     */
    string readString(uint ptr, uint len) {
        auto bytes = readMemory(ptr, len);
        return cast(string)bytes;
    }
    
    /**
     * Read an unsigned 32-bit integer from memory (little-endian)
     */
    uint readU32(uint offset) {
        auto bytes = readMemory(offset, 4);
        return *cast(uint*)bytes.ptr;
    }
    
    /**
     * Read a signed 32-bit integer from memory (little-endian)
     */
    int readI32(uint offset) {
        auto bytes = readMemory(offset, 4);
        return *cast(int*)bytes.ptr;
    }
    
    /**
     * Get memory size
     */
    uint getMemorySize() {
        if (!initialized) return 0;
        return m3_GetMemorySize(runtime);
    }
    
    /**
     * Read call stack from linear memory and format error message.
     * Called when CTFE execution fails to provide stack trace.
     */
    string formatErrorWithStack(string baseError) {
        import codegen.wasm.types : CALL_STACK_DEPTH_OFFSET, CALL_STACK_FRAMES_OFFSET,
                                    CALL_STACK_FRAME_SIZE, CALL_STACK_MAX_FRAMES;
        
        if (!initialized) return baseError;
        
        try {
            // Read stack depth
            uint depth = readU32(CALL_STACK_DEPTH_OFFSET);
            if (depth == 0 || depth > CALL_STACK_MAX_FRAMES) {
                return baseError;  // No stack or invalid
            }
            
            // Build stack trace
            string[] frames;
            for (uint i = 0; i < depth; i++) {
                uint frameAddr = CALL_STACK_FRAMES_OFFSET + i * CALL_STACK_FRAME_SIZE;
                
                uint nameOffset = readU32(frameAddr + 0);
                uint nameLen = readU32(frameAddr + 4);
                uint fileOffset = readU32(frameAddr + 8);
                uint fileLen = readU32(frameAddr + 12);
                uint line = readU32(frameAddr + 16);
                uint column = readU32(frameAddr + 20);
                
                // Read function and file names
                string funcName = "<unknown>";
                string fileName = "<unknown>";
                try {
                    if (nameLen > 0 && nameLen < 256) {
                        funcName = readString(nameOffset, nameLen);
                    }
                    if (fileLen > 0 && fileLen < 1024) {
                        fileName = readString(fileOffset, fileLen);
                    }
                } catch (Exception) {
                    // Ignore read errors
                }
                
                frames ~= format("  --> %s:%d:%d in `%s()`", fileName, line, column, funcName);
            }
            
            // Format final error message
            if (frames.length == 0) {
                return baseError;
            }
            
            string result = baseError ~ "\n\nCall stack (most recent first):";
            foreach_reverse (frame; frames) {
                result ~= "\n" ~ frame;
            }
            return result;
            
        } catch (Exception e) {
            // If anything fails, just return the base error
            return baseError;
        }
    }
}

/**
 * Simple helper to execute WASM and get i32 result
 */
CTFEValue executeWasmI32(const(ubyte)[] wasmBytes, string funcName, int[] args...) {
    auto rt = new CTFERuntime();
    scope(exit) destroy(rt);
    
    rt.loadModule(wasmBytes);
    return rt.callI32(funcName, args);
}

//==============================================================================
// Unit Tests
//==============================================================================

unittest {
    import std.stdio : writeln;
    
    // WASM module with memory and data section containing "Hello"
    // Generated from:
    // (module
    //   (memory (export "memory") 1)
    //   (data (i32.const 100) "Hello")
    //   (func (export "getPtr") (result i32) i32.const 100)
    //   (func (export "getLen") (result i32) i32.const 5)
    // )
    ubyte[] wasmWithData = [
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x00, 0x05, 0x03, 0x01, 0x00,
        0x01, 0x07, 0x1c, 0x03, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02,
        0x00, 0x06, 0x67, 0x65, 0x74, 0x50, 0x74, 0x72, 0x00, 0x00, 0x06, 0x67,
        0x65, 0x74, 0x4c, 0x65, 0x6e, 0x00, 0x01, 0x0a, 0x0c, 0x02, 0x05, 0x00,
        0x41, 0xe4, 0x00, 0x0b, 0x04, 0x00, 0x41, 0x05, 0x0b, 0x0b, 0x0c, 0x01,
        0x00, 0x41, 0xe4, 0x00, 0x0b, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f
    ];
    
    auto rt = new CTFERuntime();
    rt.loadModule(wasmWithData);
    
    // Get pointer and length from WASM functions
    auto ptr = rt.callI32("getPtr").asInt();
    auto len = rt.callI32("getLen").asInt();
    
    writeln("String at ptr=", ptr, " len=", len);
    
    // Read the string from WASM linear memory - this is the live memory access!
    auto str = rt.readString(ptr, len);
    writeln("Read from WASM memory: \"", str, "\"");
    
    assert(str == "Hello", "Expected 'Hello', got '" ~ str ~ "'");
    
    writeln("✓ Live WASM memory access test passed");
}
