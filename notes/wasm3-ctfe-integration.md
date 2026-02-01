# wasm3 Integration for CTFE

## Overview

This document outlines integrating wasm3 (a fast WebAssembly interpreter written in C) into the D-to-WASM compiler to enable Compile-Time Function Execution (CTFE).

## Why wasm3?

| Feature | wasm3 | Wasmtime | Notes |
|---------|-------|----------|-------|
| Language | Pure C | Rust (C bindings) | C is easier to integrate with D |
| Size | ~100KB | ~20MB | Smaller footprint |
| Speed | Fast interpreter | JIT | Interpreter is fine for CTFE |
| Integration | Trivial | Moderate | wasm3-d bindings already exist |
| Maintenance | Minimal (see note) | Active | wasm3 is stable but low-activity |

**Note**: wasm3 is in minimal maintenance mode due to the maintainer's circumstances (war in Ukraine). However, it's stable, well-tested, and sufficient for our CTFE needs.

## Existing D Bindings

There's already a D binding: **kassane/wasm3-d**

- Repository: https://github.com/kassane/wasm3-d
- DUB package: `wasm3-d`
- Auto-downloads and builds wasm3 as part of the build process
- Provides D-friendly wrappers around the C API

### Basic Usage

```d
import wasm3;

// Create environment and runtime
auto env = Environment(null);
auto rt = env.newRuntime(stackSizeBytes);

// Parse WASM module from bytes
auto mod = env.parseModule(wasmBytes.ptr, cast(uint)wasmBytes.length);

// Load module into runtime
m3_LoadModule(rt.runtime, mod.m_module);

// Find function by name
IM3Function func;
m3_FindFunction(&func, rt.runtime, "functionName");

// Call function (variadic)
m3_CallV(func, arg1, arg2);

// Get result from stack
int* result = cast(int*)(rt.runtime.stack);
```

## CTFE Execution Flow

```
┌─────────────────────────────────────────────────────────────┐
│  D Source with CTFE                                         │
│  enum x = fibonacci(10);  // compile-time evaluation        │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│  Compiler detects CTFE context                              │
│  - enum initializer                                         │
│  - static if condition                                      │
│  - template argument                                        │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│  Compile required functions to WASM                         │
│  - fibonacci() and any functions it calls                   │
│  - Generate binary WASM (not WAT)                           │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│  wasm3 Execution                                            │
│  - Load WASM module                                         │
│  - Execute fibonacci(10)                                    │
│  - Capture result: 55                                       │
└─────────────────┬───────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────────┐
│  Substitute result into AST                                 │
│  enum x = 55;  // now a compile-time constant               │
└─────────────────────────────────────────────────────────────┘
```

## Proposed Module: ctfe_executor.d

```d
module ctfe.executor;

import wasm3;

/// Result of CTFE execution
struct CTFEResult {
    bool success;
    string error;
    
    // Value storage (use appropriate field based on type)
    union {
        int i32Value;
        long i64Value;
        float f32Value;
        double f64Value;
    }
    
    // Type of the result
    enum Type { i32, i64, f32, f64, void_, error }
    Type type;
}

/// CTFE Executor using wasm3
class CTFEExecutor {
    private Environment env;
    private Runtime rt;
    private Module mod;
    private bool initialized;
    
    /// Initialize with stack size (default 64KB)
    this(uint stackSize = 64 * 1024) {
        env = Environment(null);
        if (env.env is null) {
            return;
        }
        rt = env.newRuntime(stackSize);
        initialized = (rt.runtime !is null);
    }
    
    /// Load a WASM module for execution
    bool loadModule(const(ubyte)[] wasmBytes) {
        if (!initialized) return false;
        
        mod = env.parseModule(cast(ubyte[])wasmBytes, cast(uint)wasmBytes.length);
        if (env.result !is null) {
            return false;
        }
        
        auto result = m3_LoadModule(rt.runtime, mod.m_module);
        return result is null;
    }
    
    /// Execute a function and return the result
    CTFEResult execute(string functionName, int[] args...) {
        CTFEResult result;
        
        if (!initialized) {
            result.success = false;
            result.error = "Executor not initialized";
            result.type = CTFEResult.Type.error;
            return result;
        }
        
        // Find function
        IM3Function func;
        auto findResult = m3_FindFunction(&func, rt.runtime, functionName.ptr);
        if (findResult !is null) {
            result.success = false;
            result.error = "Function not found: " ~ functionName;
            result.type = CTFEResult.Type.error;
            return result;
        }
        
        // Call function (simplified - real impl needs to handle different arg counts/types)
        const(char)* callResult;
        final switch (args.length) {
            case 0: callResult = m3_CallV(func); break;
            case 1: callResult = m3_CallV(func, args[0]); break;
            case 2: callResult = m3_CallV(func, args[0], args[1]); break;
            // ... extend as needed
        }
        
        if (callResult !is null) {
            import core.stdc.string : strlen;
            result.success = false;
            result.error = cast(string)callResult[0..strlen(callResult)];
            result.type = CTFEResult.Type.error;
            return result;
        }
        
        // Extract result
        result.success = true;
        result.type = CTFEResult.Type.i32;  // TODO: determine from function signature
        result.i32Value = *cast(int*)(rt.runtime.stack);
        
        return result;
    }
    
    /// Clean up
    ~this() {
        if (rt.runtime !is null) {
            rt.freeRuntime();
        }
        // Environment cleanup handled by Environment destructor
    }
}

/// Convenience function for one-shot CTFE
CTFEResult runCTFE(const(ubyte)[] wasmBytes, string functionName, int[] args...) {
    auto executor = new CTFEExecutor();
    scope(exit) destroy(executor);
    
    if (!executor.loadModule(wasmBytes)) {
        CTFEResult result;
        result.success = false;
        result.error = "Failed to load WASM module";
        result.type = CTFEResult.Type.error;
        return result;
    }
    
    return executor.execute(functionName, args);
}
```

## WAT vs Binary WASM

### Current State
- Compiler generates WAT (text format)
- Uses external `wat2wasm` tool to convert to binary WASM
- Works for regular compilation

### Problem for CTFE
- CTFE needs binary WASM to feed to wasm3
- Shelling out to wat2wasm adds latency and external dependency
- For frequent CTFE (many enum values, complex templates), this overhead adds up

### Options

#### Option 1: Keep wat2wasm (Short-term)
```d
// Shell out to wat2wasm
auto watFile = "/tmp/ctfe_" ~ randomId ~ ".wat";
auto wasmFile = "/tmp/ctfe_" ~ randomId ~ ".wasm";
std.file.write(watFile, watCode);
auto result = executeShell("wat2wasm " ~ watFile ~ " -o " ~ wasmFile);
auto wasmBytes = cast(ubyte[])std.file.read(wasmFile);
```

**Pros**: Quick to implement, leverages well-tested tool
**Cons**: External dependency, process overhead, temp files

#### Option 2: Direct Binary WASM Generation (Long-term)
Skip WAT entirely. Generate binary WASM bytes directly.

**Binary WASM structure**:
```
Magic number:    0x00 0x61 0x73 0x6D  ("\0asm")
Version:         0x01 0x00 0x00 0x00  (version 1)
Sections:        (type, import, function, memory, export, code, etc.)
```

Each section is:
```
Section ID:      1 byte
Section size:    LEB128 encoded
Section content: varies by section type
```

**Pros**: Self-contained, no external dependencies, faster
**Cons**: More implementation work, need to handle LEB128 encoding

#### Option 3: Hybrid Approach (Recommended)
1. Keep WAT generation for human-readable output and debugging
2. Add parallel binary WASM generation path
3. Use binary path for CTFE (performance critical)
4. Use WAT path for final output (can inspect/debug)

### LEB128 Encoding (for binary WASM)

```d
/// Encode unsigned LEB128
ubyte[] encodeLEB128Unsigned(ulong value) {
    ubyte[] result;
    do {
        ubyte b = cast(ubyte)(value & 0x7F);
        value >>= 7;
        if (value != 0) b |= 0x80;
        result ~= b;
    } while (value != 0);
    return result;
}

/// Encode signed LEB128
ubyte[] encodeLEB128Signed(long value) {
    ubyte[] result;
    bool more = true;
    while (more) {
        ubyte b = cast(ubyte)(value & 0x7F);
        value >>= 7;
        if ((value == 0 && !(b & 0x40)) || (value == -1 && (b & 0x40))) {
            more = false;
        } else {
            b |= 0x80;
        }
        result ~= b;
    }
    return result;
}
```

## Integration Steps

### Phase 1: Basic Integration
1. Add `wasm3-d` as a DUB dependency
2. Implement `CTFEExecutor` module
3. Test with manually-created WASM bytes
4. Shell out to `wat2wasm` for WAT→WASM conversion

### Phase 2: Direct Binary Emission
1. Implement `WasmBinaryEmitter` alongside existing `WasmGenerator`
2. Start with simple cases (functions with basic types)
3. Expand to cover all supported constructs
4. Remove `wat2wasm` dependency for CTFE path

### Phase 3: Full CTFE Support
1. Hook executor into semantic analysis phase
2. Detect CTFE contexts (enum, static if, template args)
3. Compile dependent functions to WASM
4. Execute and substitute results
5. Handle errors gracefully (CTFE failure should be a compile error)

## Memory Considerations

For CTFE, we need to think about:

1. **Stack size**: 64KB default should be plenty for most CTFE
2. **Linear memory**: May need to allocate for arrays/strings in CTFE
3. **Isolation**: Each CTFE evaluation should be independent
4. **Caching**: Consider caching compiled WASM for repeated CTFE calls to same function

## Error Handling

CTFE errors should become compile-time errors:

```d
enum x = riskyFunction();  // If this traps in wasm3, emit compile error

// Error message should include:
// - What CTFE was being evaluated
// - The wasm3 error (trap type, etc.)
// - Source location of the CTFE expression
```

## Testing Strategy

1. **Unit tests for executor**: Load known-good WASM, verify execution
2. **Integration tests**: D code with CTFE → verify compiled constants
3. **Error tests**: Verify CTFE failures produce sensible compile errors
4. **Performance tests**: Measure CTFE overhead, compare with wat2wasm path

## References

- wasm3 repository: https://github.com/wasm3/wasm3
- wasm3-d bindings: https://github.com/kassane/wasm3-d
- WebAssembly binary format: https://webassembly.github.io/spec/core/binary/
- LEB128 encoding: https://en.wikipedia.org/wiki/LEB128
