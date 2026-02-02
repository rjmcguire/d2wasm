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
private int g_stateValue = 0;

/// Host function implementations
extern(C) {
    /// Returns a constant value
    const(void)* host_get_value(wasm3.IM3Runtime runtime, wasm3.IM3ImportContext ctx, ulong* stack, void* mem) {
        // Return value is stored at stack[0]
        *stack = 42;
        return null;  // null = no error
    }
    
    /// Adds two i32 values
    const(void)* host_add(wasm3.IM3Runtime runtime, wasm3.IM3ImportContext ctx, ulong* stack, void* mem) {
        int a = cast(int)stack[0];
        int b = cast(int)stack[1];
        stack[0] = a + b;
        return null;
    }
    
    /// Sets global state
    const(void)* host_set_state(wasm3.IM3Runtime runtime, wasm3.IM3ImportContext ctx, ulong* stack, void* mem) {
        g_stateValue = cast(int)stack[0];
        return null;
    }
    
    /// Gets global state
    const(void)* host_get_state(wasm3.IM3Runtime runtime, wasm3.IM3ImportContext ctx, ulong* stack, void* mem) {
        stack[0] = g_stateValue;
        return null;
    }
    
    /// Returns a configured constant
    const(void)* host_return_constant(wasm3.IM3Runtime runtime, wasm3.IM3ImportContext ctx, ulong* stack, void* mem) {
        // The constant is passed via the user data pointer
        int value = cast(int)cast(size_t)ctx.userdata;
        stack[0] = value;
        return null;
    }
}

/// Bind a host function based on its behavior
bool bindHostFunction(wasm3.IM3Module mod, string moduleName, string funcName, JSONValue funcDef) {
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
    wasm3.M3RawCall handler;
    void* userdata = null;
    
    if (behavior == "add") {
        handler = &host_add;
    } else if (behavior == "set_state") {
        handler = &host_set_state;
    } else if (behavior == "get_state") {
        handler = &host_get_state;
    } else if ("returns" in funcDef) {
        // Constant return value
        handler = &host_return_constant;
        userdata = cast(void*)cast(size_t)funcDef["returns"].integer;
    } else {
        handler = &host_get_value;  // Default: return 42
    }
    
    auto err = wasm3.m3_LinkRawFunctionEx(mod, moduleName.toStringz, funcName.toStringz, sig.toStringz, handler, userdata);
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
    auto env = wasm3.m3_NewEnvironment();
    if (!env) {
        writeln("Failed to create wasm3 environment");
        return 1;
    }
    scope(exit) wasm3.m3_FreeEnvironment(env);
    
    auto runtime = wasm3.m3_NewRuntime(env, 64 * 1024, null);
    if (!runtime) {
        writeln("Failed to create wasm3 runtime");
        return 1;
    }
    scope(exit) wasm3.m3_FreeRuntime(runtime);
    
    // Parse module
    wasm3.IM3Module mod;
    auto err = wasm3.m3_ParseModule(env, &mod, wasmBytes.ptr, cast(uint)wasmBytes.length);
    if (err) {
        writeln("Failed to parse WASM: ", err.fromStringz);
        return 1;
    }
    
    // Bind host functions BEFORE loading module
    if ("imports" in config) {
        foreach (moduleName, funcs; config["imports"].object) {
            foreach (funcName, funcDef; funcs.object) {
                bindHostFunction(mod, moduleName, funcName, funcDef);
            }
        }
    }
    
    // Load module
    err = wasm3.m3_LoadModule(runtime, mod);
    if (err) {
        writeln("Failed to load WASM module: ", err.fromStringz);
        return 1;
    }
    
    // Find entry function
    string entryName = "entry" in config ? config["entry"].str : "result";
    wasm3.IM3Function func;
    err = wasm3.m3_FindFunction(&func, runtime, entryName.toStringz);
    if (err) {
        writeln("Failed to find function '", entryName, "': ", err.fromStringz);
        return 1;
    }
    
    // Call function
    err = wasm3.m3_Call(func, 0, null);
    if (err) {
        writeln("Execution error: ", err.fromStringz);
        return 1;
    }
    
    // Get result
    int result;
    err = wasm3.m3_GetResultsV(func, &result);
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
