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
    
    static CTFEValue fromF64(double v) {
        CTFEValue val;
        val.type = CTFEType.f64;
        val.f64Val = v;
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
    
    double asDouble() const {
        if (type != CTFEType.f64) {
            throw new Exception("CTFEValue is not an f64");
        }
        return f64Val;
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
 * Host implementation of __ctfe_write_i64
 * Building block for __writeln - prints i64 value.
 */
extern(C) const(void)* hostWriteI64(IM3Runtime runtime, IM3ImportContext ctx, uint* stack, void* mem) {
    // wasm3 raw stack: i64 occupies two 32-bit slots
    long value = *(cast(long*)&stack[0]);
    write(value);
    return null;
}

/**
 * Host implementation of __ctfe_write_f64
 * Building block for __writeln - prints f64 value.
 */
extern(C) const(void)* hostWriteF64(IM3Runtime runtime, IM3ImportContext ctx, uint* stack, void* mem) {
    // wasm3 raw stack: f64 occupies two 32-bit slots
    double value = *(cast(double*)&stack[0]);
    write(value);
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

        // Link extern(C) FFI functions (if ffi_meta custom section is present)
        linkFFIFunctions(wasmBytes);

        // Register extern(Objective-C) classes (if objc_classes section is present)
        registerObjCClasses(wasmBytes);

        // Initialize the FFI string return buffer.
        // Uses memory right after __heap_ptr for copying native C strings
        // (like UTF8String results) into WASM linear memory.
        initPtrReturnBuffer();

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
        
        // __ctfe_write_i64: void(i64)
        result = m3_LinkRawFunction(mod, "ctfe".ptr, "__ctfe_write_i64".ptr, "v(I)".ptr, &hostWriteI64);
        if (result !is null && result != m3Err_functionLookupFailed) {
            throw new CTFERuntimeError("Failed to link __ctfe_write_i64: " ~ fromStringz(result).idup);
        }

        // __ctfe_write_f64: void(f64)
        result = m3_LinkRawFunction(mod, "ctfe".ptr, "__ctfe_write_f64".ptr, "v(F)".ptr, &hostWriteF64);
        if (result !is null && result != m3Err_functionLookupFailed) {
            throw new CTFERuntimeError("Failed to link __ctfe_write_f64: " ~ fromStringz(result).idup);
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
     * Link extern(C) FFI functions by reading the ffi_meta custom section
     * from the WASM binary, dlsym-ing each function, and linking via libffi.
     */
    private void linkFFIFunctions(const(ubyte)[] wasmBytes) {
        import runtime.ffi_bindings;
        import core.sys.posix.dlfcn : dlsym;
        version (OSX) {
            import core.sys.darwin.dlfcn : RTLD_DEFAULT;
        } else {
            import core.sys.posix.dlfcn : RTLD_DEFAULT;
        }

        // Parse ffi_meta entries from WASM binary
        auto entries = parseFFIMetaSection(wasmBytes);
        if (entries.length == 0)
            return;

        foreach (ref entry; entries) {
            // Resolve native function via dlsym — use nativeName alias if present
            string lookupName = entry.nativeName.length > 0 ? entry.nativeName : entry.name;
            void* fnPtr = dlsym(RTLD_DEFAULT, lookupName.toStringz);
            if (fnPtr is null) {
                stderr.writeln("FFI warning: dlsym failed for '", lookupName, "' — skipping");
                continue;
            }

            // Build arg_kinds array for C
            int[] argKinds;
            foreach (k; entry.paramKinds) {
                argKinds ~= cast(int)k;
            }

            // Create FFI descriptor via C trampoline library
            auto desc = ffi_make_descriptor(
                entry.name.toStringz,
                fnPtr,
                cast(int)entry.retKind,
                cast(int)entry.paramKinds.length,
                argKinds.length > 0 ? argKinds.ptr : null
            );

            if (desc is null) {
                stderr.writeln("FFI warning: ffi_make_descriptor failed for '", entry.name, "'");
                continue;
            }

            // Configure struct return metadata if needed
            enum RET_STRUCT = 6;
            if (entry.retKind == RET_STRUCT && entry.retStructFieldKinds.length > 0) {
                int[] fieldKinds;
                foreach (fk; entry.retStructFieldKinds)
                    fieldKinds ~= cast(int)fk;
                ffi_configure_struct_return(
                    desc,
                    cast(int)entry.retStructSize,
                    cast(int)entry.retStructFieldKinds.length,
                    fieldKinds.length > 0 ? fieldKinds.ptr : null
                );
            }

            // Build wasm3 signature string: "ret(params)"
            string sig = buildWasm3Sig(entry.retKind, entry.paramKinds);

            // Link using m3_LinkRawFunctionEx with the generic trampoline
            auto result = m3_LinkRawFunctionEx(
                mod,
                "ffi".ptr,
                entry.name.toStringz,
                sig.toStringz,
                cast(typeof(&hostPrintI32)) &ffi_generic_trampoline,
                cast(const(void)*) desc
            );

            if (result !is null && result != m3Err_functionLookupFailed) {
                stderr.writeln("FFI warning: link failed for '", entry.name, "': ",
                    fromStringz(result).idup);
            }
        }
    }

    /**
     * Register extern(Objective-C) classes by reading the objc_classes custom section
     * from the WASM binary and calling the C registration function.
     */
    private void registerObjCClasses(const(ubyte)[] wasmBytes) {
        import runtime.ffi_bindings : objc_register_classes_from_section;

        auto sectionData = parseObjCClassesSection(wasmBytes);
        if (sectionData.length == 0)
            return;

        int result = objc_register_classes_from_section(
            sectionData.ptr, sectionData.length,
            cast(void*)runtime, cast(void*)mod
        );

        if (result > 0) {
            stderr.writeln("ObjC: registered ", result, " class(es)");
        }
    }

    /**
     * Initialize the FFI pointer-return bump allocator.
     * Sets the base to __heap_ptr value (the first free byte after the data section).
     * Native→WASM string copies (e.g. UTF8String) are placed here.
     */
    private void initPtrReturnBuffer() {
        import runtime.ffi_bindings : ffi_set_ptr_return_base;
        import std.string : toStringz;

        if (mod is null) return;
        auto global = m3_FindGlobal(mod, "__heap_ptr".toStringz());
        if (global is null) return;

        M3TaggedValue val;
        auto err = m3_GetGlobal(global, &val);
        if (err !is null) return;

        uint heapPtr = val.value.i32;
        if (heapPtr > 0) {
            ffi_set_ptr_return_base(heapPtr);
        }
    }

    /**
     * Parse the objc_classes custom section from raw WASM bytes.
     * Returns the section body (without the section name), or empty if not found.
     */
    private static const(ubyte)[] parseObjCClassesSection(const(ubyte)[] bytes) {
        if (bytes.length < 8)
            return [];

        size_t pos = 8;  // Skip WASM header

        while (pos < bytes.length) {
            ubyte sectionId = bytes[pos++];
            uint sectionLen = readLEB128(bytes, pos);
            size_t sectionEnd = pos + sectionLen;

            if (sectionId == 0) {  // Custom section
                uint nameLen = readLEB128(bytes, pos);
                if (pos + nameLen <= sectionEnd) {
                    string sectionName = cast(string) bytes[pos .. pos + nameLen];
                    pos += nameLen;

                    if (sectionName == "objc_classes") {
                        return bytes[pos .. sectionEnd];
                    }
                }
            }

            pos = sectionEnd;
        }

        return [];
    }

    /// Parsed FFI metadata entry
    private struct FFIMetaEntry {
        string name;
        ubyte retKind;
        ubyte[] paramKinds;
        string nativeName;  // if set, dlsym uses this instead of name
        // Struct return metadata (only valid when retKind == RET_STRUCT)
        uint retStructSize;
        ubyte[] retStructFieldKinds;
    }

    /**
     * Parse the ffi_meta custom section from raw WASM bytes.
     * Returns empty array if no such section exists.
     */
    private static FFIMetaEntry[] parseFFIMetaSection(const(ubyte)[] bytes) {
        if (bytes.length < 8)
            return [];

        // Skip WASM header (magic + version = 8 bytes)
        size_t pos = 8;

        while (pos < bytes.length) {
            ubyte sectionId = bytes[pos++];
            uint sectionLen = readLEB128(bytes, pos);
            size_t sectionEnd = pos + sectionLen;

            if (sectionId == 0) {  // Custom section
                // Read section name
                uint nameLen = readLEB128(bytes, pos);
                if (pos + nameLen <= sectionEnd) {
                    string sectionName = cast(string) bytes[pos .. pos + nameLen];
                    pos += nameLen;

                    if (sectionName == "ffi_meta") {
                        return parseFFIMetaBody(bytes[pos .. sectionEnd]);
                    }
                }
            }

            pos = sectionEnd;
        }

        return [];
    }

    /// Parse the body of an ffi_meta section
    private static FFIMetaEntry[] parseFFIMetaBody(const(ubyte)[] data) {
        size_t pos = 0;
        uint count = readLEB128(data, pos);

        FFIMetaEntry[] entries;
        entries.reserve(count);

        for (uint i = 0; i < count && pos < data.length; i++) {
            FFIMetaEntry entry;

            // Function name
            uint nameLen = readLEB128(data, pos);
            if (pos + nameLen > data.length) break;
            entry.name = (cast(string) data[pos .. pos + nameLen]).idup;
            pos += nameLen;

            // Return kind
            if (pos >= data.length) break;
            entry.retKind = data[pos++];

            // Struct return metadata (when retKind == RET_STRUCT == 6)
            enum RET_STRUCT = 6;
            if (entry.retKind == RET_STRUCT) {
                entry.retStructSize = readLEB128(data, pos);
                if (pos < data.length) {
                    ubyte fieldCount = data[pos++];
                    if (pos + fieldCount <= data.length) {
                        entry.retStructFieldKinds = data[pos .. pos + fieldCount].dup;
                        pos += fieldCount;
                    }
                }
            }

            // Parameter count and kinds
            if (pos >= data.length) break;
            ubyte paramCount = data[pos++];
            if (pos + paramCount > data.length) break;
            entry.paramKinds = data[pos .. pos + paramCount].dup;
            pos += paramCount;

            // Optional native name alias
            if (pos < data.length) {
                ubyte hasNative = data[pos++];
                if (hasNative != 0 && pos < data.length) {
                    uint nativeLen = readLEB128(data, pos);
                    if (pos + nativeLen <= data.length) {
                        entry.nativeName = (cast(string) data[pos .. pos + nativeLen]).idup;
                        pos += nativeLen;
                    }
                }
            }

            entries ~= entry;
        }

        return entries;
    }

    /// Read a LEB128-encoded unsigned integer, advancing pos
    private static uint readLEB128(const(ubyte)[] data, ref size_t pos) {
        uint result = 0;
        uint shift = 0;
        while (pos < data.length) {
            ubyte b = data[pos++];
            result |= cast(uint)(b & 0x7F) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
        }
        return result;
    }

    /// Build wasm3 signature string from ArgKinds.
    /// Format: "ret(params)" where i=i32, I=i64, f=f32, F=f64, v=void
    private static string buildWasm3Sig(ubyte retKind, const(ubyte)[] paramKinds) {
        char[] sig;

        // Return type
        sig ~= argKindToSigChar(retKind, true);
        sig ~= '(';

        // Parameters
        foreach (k; paramKinds) {
            sig ~= argKindToSigChar(k, false);
        }

        sig ~= ')';
        return cast(string) sig;
    }

    private static char argKindToSigChar(ubyte kind, bool isReturn) {
        // ArgKind enum values matching emitter
        enum : ubyte { ARG_I32=0, ARG_I64=1, ARG_F32=2, ARG_F64=3, ARG_PTR=4, RET_VOID=5, RET_STRUCT_=6 }
        switch (kind) {
            case ARG_I32: return 'i';
            case ARG_I64: return 'I';
            case ARG_F32: return 'f';
            case ARG_F64: return 'F';
            case ARG_PTR: return 'i';  // Pointers are i32 in WASM
            case RET_VOID: return 'v';
            case RET_STRUCT_: return 'v';  // WASM sig is void — struct written to memory via result_ptr
            default: return 'i';
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

        // Clear callback error state and reset FFI string buffer before execution
        clearCallbackError();
        import runtime.ffi_bindings : ffi_reset_ptr_return_bump;
        ffi_reset_ptr_return_bump();

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

        // Check for ObjC callback errors that occurred during execution
        checkCallbackError();
        
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
     * Call a function that returns f64
     */
    CTFEValue callF64(string funcName) {
        if (!initialized) {
            throw new CTFERuntimeError("Runtime not initialized");
        }

        IM3Function func;
        auto result = m3_FindFunction(&func, runtime, funcName.toStringz());
        if (result !is null) {
            throw new CTFERuntimeError("Function not found: " ~ funcName ~ " - " ~ fromStringz(result).idup);
        }

        clearCallbackError();
        result = m3_CallV(func);
        if (result !is null) {
            string baseError = "CTFE execution failed: " ~ fromStringz(result).idup;
            throw new CTFERuntimeError(formatErrorWithStack(baseError));
        }
        checkCallbackError();

        // Get f64 return value
        double returnValue;
        auto getResult = m3_GetResultsV(func, &returnValue);
        if (getResult !is null) {
            // No result is OK for some functions
        }

        return CTFEValue.fromF64(returnValue);
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

        clearCallbackError();
        result = m3_CallV(func);
        if (result !is null) {
            string baseError = "CTFE execution failed: " ~ fromStringz(result).idup;
            throw new CTFERuntimeError(formatErrorWithStack(baseError));
        }
        checkCallbackError();

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
     * Read a WASM global variable by name, returning its i32 value.
     * Returns 0 if the global is not found.
     */
    int getGlobalI32(string name) {
        if (!initialized || mod is null) return 0;

        import std.string : toStringz;
        auto global = m3_FindGlobal(mod, name.toStringz());
        if (global is null) return 0;

        M3TaggedValue val;
        auto err = m3_GetGlobal(global, &val);
        if (err !is null) return 0;

        return cast(int)val.value.i32;
    }

    /**
     * Get memory size
     */
    uint getMemorySize() {
        if (!initialized) return 0;
        return m3_GetMemorySize(runtime);
    }
    
    /// A single call stack frame read from WASM linear memory.
    struct CallStackFrame {
        string funcName;
        string fileName;
        uint line;
        uint column;
    }

    /**
     * Read call stack frames from linear memory as structured data.
     * Returns frames from bottom (first called) to top (most recent).
     */
    CallStackFrame[] getCallStackFrames() {
        import codegen.wasm.types : CALL_STACK_DEPTH_OFFSET, CALL_STACK_FRAMES_OFFSET,
                                    CALL_STACK_FRAME_SIZE, CALL_STACK_MAX_FRAMES;

        if (!initialized) return null;

        try {
            uint depth = readU32(CALL_STACK_DEPTH_OFFSET);
            if (depth == 0 || depth > CALL_STACK_MAX_FRAMES)
                return null;

            CallStackFrame[] result;
            for (uint i = 0; i < depth; i++) {
                uint frameAddr = CALL_STACK_FRAMES_OFFSET + i * CALL_STACK_FRAME_SIZE;

                uint nameOffset = readU32(frameAddr + 0);
                uint nameLen = readU32(frameAddr + 4);
                uint fileOffset = readU32(frameAddr + 8);
                uint fileLen = readU32(frameAddr + 12);

                CallStackFrame frame;
                frame.line = readU32(frameAddr + 16);
                frame.column = readU32(frameAddr + 20);
                frame.funcName = "<unknown>";
                frame.fileName = "<unknown>";
                try {
                    if (nameLen > 0 && nameLen < 256)
                        frame.funcName = readString(nameOffset, nameLen);
                    if (fileLen > 0 && fileLen < 1024)
                        frame.fileName = readString(fileOffset, fileLen);
                } catch (Exception) {}
                result ~= frame;
            }
            return result;
        } catch (Exception) {
            return null;
        }
    }

    /**
     * Check if an ObjC callback error occurred during WASM execution.
     * The C trampoline sets a global error string when m3_Call fails inside a callback.
     */
    private void clearCallbackError() {
        import runtime.ffi_bindings : ffi_clear_callback_error;
        ffi_clear_callback_error();
    }

    private void checkCallbackError() {
        import runtime.ffi_bindings : ffi_get_callback_error;
        import semantic.ctfe : CTFEError;
        import ast.nodes : SourceLocation;
        auto err = ffi_get_callback_error();
        if (err !is null) {
            string msg = fromStringz(err).idup;
            throw new CTFEError(msg, SourceLocation.init);
        }
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
            string result = baseError;

            // Exception location is now read from exception slots by the backend
            // (checkUncaughtException / buildTrapResult). This function only appends
            // the call stack trace.

            // Read stack depth
            uint depth = readU32(CALL_STACK_DEPTH_OFFSET);
            if (depth == 0 || depth > CALL_STACK_MAX_FRAMES) {
                return result;
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
            if (frames.length > 0) {
                result ~= "\n\nCall stack (most recent first):";
                foreach_reverse (frame; frames) {
                    result ~= "\n" ~ frame;
                }
            }
            return result;

        } catch (Exception e) {
            // If anything fails, just return the base error
            return baseError;
        }
    }
}

/// Read a source line from file (1-indexed), caching results
private string readSourceLine(string filePath, uint line) nothrow {
    import codegen.native.codegen_interface : getSourceLine;
    return getSourceLine(filePath, line);
}

/// Generate a string of N spaces
private string spaces(size_t n) nothrow {
    if (n == 0) return "";
    try {
        char[] s = new char[n];
        s[] = ' ';
        return cast(string)s;
    } catch (Exception) {
        return "";
    }
}

/// Left-pad a string to a minimum width
private string padLeft(string s, size_t width) nothrow {
    if (s.length >= width) return s;
    try {
        char[] padding = new char[width - s.length];
        padding[] = ' ';
        return cast(string)padding ~ s;
    } catch (Exception) {
        return s;
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
