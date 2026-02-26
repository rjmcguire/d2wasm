/++ dub.sdl:
    name "import_test_harness"
    dependency "wasm3-d" version="~>0.3.0"
+/
/**
 * Test harness for WASM import tests.
 * 
 * Loads a WASM module, binds host functions from config.json,
 * runs the entry function, and checks the result.
 * 
 * IMPORTANT: Keep this minimal. Logic belongs in the compiler, not here.
 * This harness only provides test host functions - it does NOT implement
 * any compiler functionality.
 */
module import_test_harness;

import std.stdio;
import std.file;
import std.json;
import std.conv;
import std.string;

//==============================================================================
// wasm3 bindings - our own correct declarations
// (wasm3-d has incorrect uint* instead of uint64_t* for stack pointer)
//==============================================================================

import core.stdc.stdint : uint8_t, uint32_t, uint64_t;

extern(C) @nogc nothrow {
    struct M3Environment;
    struct M3Runtime;
    struct M3Module;
    struct M3Function;
    
    alias IM3Environment = M3Environment*;
    alias IM3Runtime = M3Runtime*;
    alias IM3Module = M3Module*;
    alias IM3Function = M3Function*;
    
    struct M3ImportContext {
        void* userdata;
        IM3Function function_;
    }
    alias IM3ImportContext = M3ImportContext*;
    
    // Correct signature: uint64_t* not uint*
    alias M3RawCall = const(void)* function(
        IM3Runtime runtime,
        IM3ImportContext ctx,
        uint64_t* sp,
        void* mem
    );
    
    IM3Environment m3_NewEnvironment();
    void m3_FreeEnvironment(IM3Environment env);
    
    IM3Runtime m3_NewRuntime(IM3Environment env, uint32_t stackSize, void* userData);
    void m3_FreeRuntime(IM3Runtime runtime);
    
    const(char)* m3_ParseModule(IM3Environment env, IM3Module* outModule, 
                                 const(uint8_t)* wasmBytes, uint32_t wasmSize);
    const(char)* m3_LoadModule(IM3Runtime runtime, IM3Module module_);
    const(char)* m3_LinkRawFunctionEx(IM3Module module_, const(char)* moduleName,
                                       const(char)* functionName, const(char)* signature,
                                       M3RawCall function_, const(void)* userData);
    const(char)* m3_FindFunction(IM3Function* outFunction, IM3Runtime runtime, 
                                  const(char)* functionName);
    const(char)* m3_CallV(IM3Function function_, ...);
    const(char)* m3_GetResultsV(IM3Function function_, ...);
}

//==============================================================================
// Host function implementations
//==============================================================================

/// Global state for stateful host functions
private __gshared int g_stateValue = 0;

extern(C) @nogc nothrow {
    /// Returns a constant value (42)
    const(void)* host_get_value(IM3Runtime runtime, IM3ImportContext ctx, uint64_t* sp, void* mem) {
        sp[0] = 42;
        return null;
    }
    
    /// Adds two i32 values
    /// Stack layout for i(ii): sp[0]=return, sp[1]=arg0, sp[2]=arg1
    const(void)* host_add(IM3Runtime runtime, IM3ImportContext ctx, uint64_t* sp, void* mem) {
        int a = cast(int)(sp[1] & 0xFFFFFFFF);
        int b = cast(int)(sp[2] & 0xFFFFFFFF);
        sp[0] = cast(uint64_t)(a + b);
        return null;
    }
    
    /// Sets global state
    /// Stack layout for v(i): sp[0]=arg0 (no return slot for void)
    const(void)* host_set_state(IM3Runtime runtime, IM3ImportContext ctx, uint64_t* sp, void* mem) {
        g_stateValue = cast(int)(sp[0] & 0xFFFFFFFF);
        return null;
    }
    
    /// Gets global state
    const(void)* host_get_state(IM3Runtime runtime, IM3ImportContext ctx, uint64_t* sp, void* mem) {
        sp[0] = cast(uint64_t)g_stateValue;
        return null;
    }
    
    /// Returns a configured constant (via userdata)
    const(void)* host_return_constant(IM3Runtime runtime, IM3ImportContext ctx, uint64_t* sp, void* mem) {
        int value = cast(int)cast(size_t)ctx.userdata;
        sp[0] = cast(uint64_t)value;
        return null;
    }
}

//==============================================================================
// Test harness main
//==============================================================================

/// Bind a host function based on its behavior
bool bindHostFunction(IM3Module mod, string moduleName, string funcName, JSONValue funcDef) {
    string behavior = "behavior" in funcDef ? funcDef["behavior"].str : "";
    string result = "result" in funcDef ? (funcDef["result"].type == JSONType.null_ ? "" : funcDef["result"].str) : "";
    
    // Build signature string for wasm3
    string sig;
    if (result == "i32") sig ~= "i";
    else if (result == "") sig ~= "v";
    
    sig ~= "(";
    if ("params" in funcDef) {
        foreach (p; funcDef["params"].array) {
            if (p.str == "i32") sig ~= "i";
        }
    }
    sig ~= ")";
    
    // Select handler based on behavior
    M3RawCall handler;
    void* userdata = null;
    
    if (behavior == "add") {
        handler = &host_add;
    } else if (behavior == "set_state") {
        handler = &host_set_state;
    } else if (behavior == "get_state") {
        handler = &host_get_state;
    } else if ("returns" in funcDef) {
        handler = &host_return_constant;
        userdata = cast(void*)cast(size_t)funcDef["returns"].integer;
    } else {
        handler = &host_get_value;
    }
    
    auto err = m3_LinkRawFunctionEx(mod, moduleName.toStringz, funcName.toStringz, 
                                     sig.toStringz, handler, userdata);
    if (err) {
        writeln("Warning: Failed to link ", moduleName, ".", funcName, ": ", err.fromStringz);
        return false;
    }
    return true;
}

int main(string[] args) {
    if (args.length < 3) {
        writeln("Usage: import_test_harness <wasm_file> <config_file>");
        return 1;
    }
    
    string wasmFile = args[1];
    string configFile = args[2];
    
    // Load config
    JSONValue config;
    try {
        config = parseJSON(readText(configFile));
    } catch (Exception e) {
        writeln("Failed to load config: ", e.msg);
        return 1;
    }
    
    // Load WASM
    ubyte[] wasmBytes;
    try {
        wasmBytes = cast(ubyte[])read(wasmFile);
    } catch (Exception e) {
        writeln("Failed to load WASM: ", e.msg);
        return 1;
    }
    
    // Initialize wasm3
    auto env = m3_NewEnvironment();
    if (!env) {
        writeln("Failed to create wasm3 environment");
        return 1;
    }
    scope(exit) m3_FreeEnvironment(env);
    
    auto runtime = m3_NewRuntime(env, 64 * 1024, null);
    if (!runtime) {
        writeln("Failed to create wasm3 runtime");
        return 1;
    }
    scope(exit) m3_FreeRuntime(runtime);
    
    // Parse module
    IM3Module mod;
    auto err = m3_ParseModule(env, &mod, wasmBytes.ptr, cast(uint)wasmBytes.length);
    if (err) {
        writeln("Failed to parse WASM: ", err.fromStringz);
        return 1;
    }
    
    // Load module
    err = m3_LoadModule(runtime, mod);
    if (err) {
        writeln("Failed to load WASM module: ", err.fromStringz);
        return 1;
    }
    
    // Bind host functions AFTER loading module
    if ("imports" in config) {
        foreach (moduleName, funcs; config["imports"].object) {
            foreach (funcName, funcDef; funcs.object) {
                bindHostFunction(mod, moduleName, funcName, funcDef);
            }
        }
    }
    
    // Find entry function
    string entryName;
    if (auto p = "mangled_entry" in config)
        entryName = p.str;
    else if (auto p = "entry" in config)
        entryName = p.str;
    else
        entryName = "result";
    IM3Function func;
    err = m3_FindFunction(&func, runtime, entryName.toStringz);
    if (err) {
        writeln("Failed to find function '", entryName, "': ", err.fromStringz);
        return 1;
    }
    
    // Call function
    err = m3_CallV(func);
    if (err) {
        writeln("Execution error: ", err.fromStringz);
        return 1;
    }
    
    // Get result
    int result;
    err = m3_GetResultsV(func, &result);
    if (err) {
        writeln("Failed to get result: ", err.fromStringz);
        return 1;
    }
    
    // Check expected
    if ("expected_result" in config) {
        int expected = cast(int)config["expected_result"].integer;
        if (result == expected) {
            writeln("PASS: result = ", result);
            return 0;
        } else {
            writeln("FAIL: expected ", expected, ", got ", result);
            return 1;
        }
    } else {
        writeln("Result: ", result);
        return 0;
    }
}
