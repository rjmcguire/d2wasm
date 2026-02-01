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
        
        initialized = true;
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
            throw new CTFERuntimeError("CTFE execution failed: " ~ fromStringz(result).idup);
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
            throw new CTFERuntimeError("CTFE execution failed: " ~ fromStringz(result).idup);
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
     * Get memory size
     */
    uint getMemorySize() {
        if (!initialized) return 0;
        return m3_GetMemorySize(runtime);
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
