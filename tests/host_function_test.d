/++ dub.sdl:
name "host_function_test"
dependency "wasm3-d" version="0.3.0"
+/
/**
 * Test: Prove that WASM can call host functions via m3_LinkRawFunction
 */
module host_function_test;

import wasm3.binding.binding;
import std.stdio;
import std.string;
import std.file;

// Global to capture what the host function received
__gshared int lastLoggedValue = -1;

// Host function implementation - called from WASM
extern(C) const(void)* host_log_impl(IM3Runtime runtime, IM3ImportContext ctx, uint* stack, void* mem) {
    // First stack slot is the i32 argument
    int value = cast(int)(*stack);
    lastLoggedValue = value;
    writeln("HOST: __host_log called with value = ", value);
    return null;  // No error
}

void main() {
    writeln("=== Host Function Linking Test ===\n");
    
    // Read the WASM file
    auto wasmBytes = cast(ubyte[])read("/tmp/host_test.wasm");
    writeln("Loaded ", wasmBytes.length, " bytes of WASM");
    
    // Create wasm3 environment and runtime
    auto env = m3_NewEnvironment();
    if (!env) {
        writeln("ERROR: Failed to create environment");
        return;
    }
    scope(exit) m3_FreeEnvironment(env);
    
    auto runtime = m3_NewRuntime(env, 64 * 1024, null);
    if (!runtime) {
        writeln("ERROR: Failed to create runtime");
        return;
    }
    scope(exit) m3_FreeRuntime(runtime);
    
    // Parse the module
    IM3Module mod;
    auto parseResult = m3_ParseModule(env, &mod, wasmBytes.ptr, cast(uint)wasmBytes.length);
    if (parseResult) {
        writeln("ERROR: Failed to parse module: ", fromStringz(parseResult));
        return;
    }
    writeln("Module parsed successfully");
    
    // Load the module (but don't link yet)
    auto loadResult = m3_LoadModule(runtime, mod);
    if (loadResult) {
        writeln("ERROR: Failed to load module: ", fromStringz(loadResult));
        return;
    }
    writeln("Module loaded");
    
    // Link our host function
    auto linkResult = m3_LinkRawFunction(mod, "ctfe".ptr, "__host_log".ptr, "v(i)".ptr, &host_log_impl);
    if (linkResult && linkResult != m3Err_functionLookupFailed) {
        writeln("ERROR: Failed to link host function: ", fromStringz(linkResult));
        return;
    }
    writeln("Host function linked");
    
    // Find and call the compute function
    IM3Function computeFunc;
    auto findResult = m3_FindFunction(&computeFunc, runtime, "compute");
    if (findResult) {
        writeln("ERROR: Failed to find compute function: ", fromStringz(findResult));
        return;
    }
    writeln("Found compute function");
    
    // Call compute(3, 5) - should return 8 and call __host_log(8)
    auto callResult = m3_CallV(computeFunc, 3, 5);
    if (callResult) {
        writeln("ERROR: Call failed: ", fromStringz(callResult));
        return;
    }
    
    // Get return value
    uint retVal;
    m3_GetResultsV(computeFunc, &retVal);
    
    writeln("\n=== Results ===");
    writeln("compute(3, 5) returned: ", retVal);
    writeln("Host function received: ", lastLoggedValue);
    
    if (retVal == 8 && lastLoggedValue == 8) {
        writeln("\n✓ SUCCESS: WASM computed correctly AND called host function!");
    } else {
        writeln("\n✗ FAILURE: Expected return=8, host=8, got return=", retVal, ", host=", lastLoggedValue);
    }
}
