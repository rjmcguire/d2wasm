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

// wasm3 bindings
import wasm3;

/// Global state for stateful host functions
private __gshared int g_stateValue = 0;

/// Configured return values (for constant-returning functions)
private __gshared int[string] g_returnValues;

/// Host function implementations - must match M3RawCall signature exactly
extern(C) nothrow @nogc @system {
    /// Returns a constant value (42)
    const(void)* host_get_value(IM3Runtime runtime, IM3ImportContext ctx, ulong* sp, void* mem) {
        // Return value is stored at sp[0]
        sp[0] = 42;
        return null;  // null = no error
    }
    
    /// Adds two i32 values
    const(void)* host_add(IM3Runtime runtime, IM3ImportContext ctx, ulong* sp, void* mem) {
        // wasm3 raw call: sp[0] = return slot, args at sp[1], sp[2], ...
        int a = cast(int)(sp[1] & 0xFFFFFFFF);
        int b = cast(int)(sp[2] & 0xFFFFFFFF);
        sp[0] = cast(ulong)(a + b);
        return null;
    }
    
    /// Sets global state
    const(void)* host_set_state(IM3Runtime runtime, IM3ImportContext ctx, ulong* sp, void* mem) {
        // For void functions: sp[0] = first arg (no return slot)
        g_stateValue = cast(int)(sp[0] & 0xFFFFFFFF);
        return null;
    }
    
    /// Gets global state
    const(void)* host_get_state(IM3Runtime runtime, IM3ImportContext ctx, ulong* sp, void* mem) {
        sp[0] = cast(uint)g_stateValue;
        return null;
    }
    
    /// Returns a configured constant (from userdata)
    const(void)* host_return_constant(IM3Runtime runtime, IM3ImportContext ctx, ulong* sp, void* mem) {
        // The constant is passed via the user data pointer
        int value = cast(int)cast(size_t)ctx.userdata;
        sp[0] = cast(uint)value;
        return null;
    }
}

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
    
    // Note: wasm3-d binding declares M3RawCall with uint* but actual wasm3 uses uint64_t*
    // We use ulong* in our handlers and cast here
    if (behavior == "add") {
        handler = cast(M3RawCall)&host_add;
    } else if (behavior == "set_state") {
        handler = cast(M3RawCall)&host_set_state;
    } else if (behavior == "get_state") {
        handler = cast(M3RawCall)&host_get_state;
    } else if ("returns" in funcDef) {
        // Constant return value
        handler = cast(M3RawCall)&host_return_constant;
        userdata = cast(void*)cast(size_t)funcDef["returns"].integer;
    } else {
        handler = cast(M3RawCall)&host_get_value;  // Default: return 42
    }
    
    auto err = m3_LinkRawFunctionEx(mod, moduleName.toStringz, funcName.toStringz, sig.toStringz, handler, userdata);
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
    
    // Load module first
    err = m3_LoadModule(runtime, mod);
    if (err) {
        writeln("Failed to load WASM module: ", err.fromStringz);
        return 1;
    }
    
    // Then bind host functions AFTER loading module
    if ("imports" in config) {
        foreach (moduleName, funcs; config["imports"].object) {
            foreach (funcName, funcDef; funcs.object) {
                bindHostFunction(mod, moduleName, funcName, funcDef);
            }
        }
    }
    
    // Find entry function
    string entryName = "entry" in config ? config["entry"].str : "result";
    IM3Function func;
    err = m3_FindFunction(&func, runtime, entryName.toStringz);
    if (err) {
        writeln("Failed to find function '", entryName, "': ", err.fromStringz);
        return 1;
    }
    
    // Call function (no arguments)
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
