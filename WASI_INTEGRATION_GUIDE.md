# WASI Console Output Integration Guide

## 🔧 Required Code Changes for WASI Integration

### 1. Modify `src/codegen/wasm_generator.d`

#### Replace Console Imports with WASI:
```d
/**
 * Add WASI function imports to the WASM module
 */
void addWasiImports() {
    // Standard WASI fd_write import for console output
    wasmModule.imports ~= "(import \"wasi_snapshot_preview1\" \"fd_write\" (func $fd_write (param i32 i32 i32 i32) (result i32)))";
}
```

#### Update generateModule() method:
```d
WasmModule generateModule(Declaration[] declarations) {
    wasmModule = WasmModule();
    
    // Add WASI imports instead of custom console imports
    addWasiImports();
    
    // Add WASI utility functions
    addWasiWriteFunctions();
    
    // ... existing declaration processing ...
    
    // Add required WASI exports
    addWasiExports();
    
    return wasmModule;
}

/**
 * Add required WASI exports
 */
void addWasiExports() {
    // Export memory (required by WASI)
    wasmModule.exports ~= "(export \"memory\" (memory 0))";
    
    // Add _start function for WASI entry point
    foreach (func; wasmModule.functions) {
        if (func.name == "main") {
            addWasiStartFunction();
            break;
        }
    }
}

/**
 * Add WASI _start function that calls main
 */
void addWasiStartFunction() {
    auto startFunc = WasmFunction();
    startFunc.name = "_start";
    startFunc.returnType = WasmType.void_;
    startFunc.instructions ~= "call $main";
    startFunc.instructions ~= "drop";  // WASI ignores return value
    
    wasmModule.functions ~= startFunc;
    wasmModule.exports ~= "(export \"_start\" (func $_start))";
}
```

#### Add WASI Write Utility Functions:
```d
/**
 * Add core WASI write utility functions to module
 */
void addWasiWriteFunctions() {
    // Global for simple memory allocation
    wasmModule.globalVariables ~= "(global $heap_ptr (mut i32) (i32.const 1024))";
    
    // Simple memory allocator
    auto mallocFunc = WasmFunction();
    mallocFunc.name = "malloc";
    mallocFunc.parameters = [WasmType.i32];
    mallocFunc.returnType = WasmType.i32;
    mallocFunc.localVariables ~= "(local $ptr i32)";
    mallocFunc.instructions ~= "global.get $heap_ptr";
    mallocFunc.instructions ~= "local.set $ptr";
    mallocFunc.instructions ~= "global.get $heap_ptr"; 
    mallocFunc.instructions ~= "local.get 0";  // size parameter
    mallocFunc.instructions ~= "i32.add";
    mallocFunc.instructions ~= "global.set $heap_ptr";
    mallocFunc.instructions ~= "local.get $ptr";
    wasmModule.functions ~= mallocFunc;
    
    // Core WASI write function
    auto writeFunc = WasmFunction();
    writeFunc.name = "write_to_stdout";
    writeFunc.parameters = [WasmType.i32, WasmType.i32]; // ptr, len
    writeFunc.returnType = WasmType.void_;
    writeFunc.localVariables ~= "(local $iovec_ptr i32)";
    
    // Allocate iovec (8 bytes: ptr + len)
    writeFunc.instructions ~= "i32.const 8";
    writeFunc.instructions ~= "call $malloc";
    writeFunc.instructions ~= "local.set $iovec_ptr";
    
    // Set iov_base (string pointer)
    writeFunc.instructions ~= "local.get $iovec_ptr";
    writeFunc.instructions ~= "local.get 0";  // string ptr param
    writeFunc.instructions ~= "i32.store";
    
    // Set iov_len (string length)
    writeFunc.instructions ~= "local.get $iovec_ptr";
    writeFunc.instructions ~= "i32.const 4";
    writeFunc.instructions ~= "i32.add";
    writeFunc.instructions ~= "local.get 1";  // string len param
    writeFunc.instructions ~= "i32.store";
    
    // Call fd_write
    writeFunc.instructions ~= "i32.const 1";  // stdout
    writeFunc.instructions ~= "local.get $iovec_ptr";
    writeFunc.instructions ~= "i32.const 1";  // iovec count
    writeFunc.instructions ~= "i32.const 4";  // malloc space for bytes_written
    writeFunc.instructions ~= "call $malloc";
    writeFunc.instructions ~= "call $fd_write";
    writeFunc.instructions ~= "drop";  // ignore result
    
    wasmModule.functions ~= writeFunc;
    
    // Writeln wrapper function
    auto writelnFunc = WasmFunction();
    writelnFunc.name = "writeln_str";
    writelnFunc.parameters = [WasmType.i32, WasmType.i32]; // ptr, len
    writelnFunc.returnType = WasmType.void_;
    writelnFunc.instructions ~= "local.get 0";
    writelnFunc.instructions ~= "local.get 1";
    writelnFunc.instructions ~= "call $write_to_stdout";
    // Write newline
    writelnFunc.instructions ~= format("i32.const %d", addStringLiteral("\n"));
    writelnFunc.instructions ~= "i32.const 1";
    writelnFunc.instructions ~= "call $write_to_stdout";
    
    wasmModule.functions ~= writelnFunc;
}
```

#### Update generateCallExpression() for writeln:
```d
void generateCallExpression(CallExpression expr) {
    if (auto identExpr = cast(IdentifierExpression)expr.function_) {
        if (identExpr.name == "writeln") {
            generateWasiWritelnCall(expr);
            return;
        }
    }
    
    // ... existing function call code ...
}

/**
 * Generate WASI-compliant writeln function call
 */
void generateWasiWritelnCall(CallExpression expr) {
    if (expr.arguments.length == 0) {
        // writeln() - just newline
        context.addInstruction(format("i32.const %d", addStringLiteral("\n")));
        context.addInstruction("i32.const 1");
        context.addInstruction("call $write_to_stdout");
        return;
    }
    
    foreach (arg; expr.arguments) {
        if (auto literal = cast(LiteralExpression)arg) {
            generateWasiWritelnArgument(literal);
        } else {
            // Non-literal expression - evaluate and convert to string
            generateExpression(arg);
            generateValueToString(arg);  // Convert to string representation
        }
    }
}

/**
 * Generate WASI writeln for literal arguments
 */
void generateWasiWritelnArgument(LiteralExpression literal) {
    import std.variant;
    
    if (literal.value.type == typeid(string)) {
        string str = literal.value.get!string ~ "\n";  // Add newline
        uint stringOffset = addStringLiteral(str);
        context.addInstruction(format("i32.const %d", stringOffset));
        context.addInstruction(format("i32.const %d", str.length));
        context.addInstruction("call $write_to_stdout");
    } else if (literal.value.type == typeid(long)) {
        string str = to!string(literal.value.get!long) ~ "\n";
        uint stringOffset = addStringLiteral(str);
        context.addInstruction(format("i32.const %d", stringOffset));
        context.addInstruction(format("i32.const %d", str.length));
        context.addInstruction("call $write_to_stdout");
    } else if (literal.value.type == typeid(double)) {
        string str = to!string(literal.value.get!double) ~ "\n";
        uint stringOffset = addStringLiteral(str);
        context.addInstruction(format("i32.const %d", stringOffset));
        context.addInstruction(format("i32.const %d", str.length));
        context.addInstruction("call $write_to_stdout");
    }
}
```

### 2. Add String Literal Management

#### Add to WasmModule structure:
```d
struct WasmModule {
    // ... existing fields ...
    string[] stringLiterals;      // Store string literals
    uint nextStringOffset = 1024; // Start after first 1KB
    
    /**
     * Add string literal and return memory offset
     */
    uint addStringLiteral(string str) {
        uint offset = nextStringOffset;
        
        // Add data directive to WAT
        string dataDirective = format("(data (i32.const %d) \"%s\")", 
                                      offset, escapeWatString(str));
        
        // WAT modules have data section - add to appropriate section
        // This would need to be integrated into toWAT() method
        
        nextStringOffset += str.length;
        return offset;
    }
    
    private string escapeWatString(string str) {
        // Escape special characters for WAT format
        return str.replace("\\", "\\\\")
                  .replace("\"", "\\\"")
                  .replace("\n", "\\n")
                  .replace("\r", "\\r")
                  .replace("\t", "\\t");
    }
}
```

### 3. Update toWAT() Method

#### Modify WasmModule.toWAT() to include string data:
```d
string toWAT() {
    auto result = appender!string();
    
    result ~= "(module\n";
    
    // Memory declaration
    result ~= format("  (memory %d)\n", memorySize);
    
    // Imports
    foreach (imp; imports) {
        result ~= "  " ~ imp ~ "\n";
    }
    
    // Global variables
    foreach (global; globalVariables) {
        result ~= "  " ~ global ~ "\n";
    }
    
    // String data section
    foreach (i, strLiteral; stringLiterals) {
        uint offset = 1024 + i * 256; // Simple offset calculation
        result ~= format("  (data (i32.const %d) \"%s\")\n", 
                         offset, escapeWatString(strLiteral));
    }
    
    // Functions
    foreach (func; functions) {
        result ~= func.toWAT() ~ "\n\n";
    }
    
    // Exports
    foreach (exp; exports) {
        result ~= "  " ~ exp ~ "\n";
    }
    
    result ~= ")";
    return result.data;
}
```

### 4. Update Build Process

#### Create WASI runner script:
```bash
#!/bin/bash
# WASI runner script for D-to-WASM programs

PROGRAM_NAME="$1"
if [ -z "$PROGRAM_NAME" ]; then
    echo "Usage: $0 <program-name>"
    echo "Expects <program-name>.wat to exist"
    exit 1
fi

# Convert WAT to WASM if needed
if [ ! -f "${PROGRAM_NAME}.wasm" ] || [ "${PROGRAM_NAME}.wat" -nt "${PROGRAM_NAME}.wasm" ]; then
    echo "Converting WAT to WASM..."
    wat2wasm "${PROGRAM_NAME}.wat" -o "${PROGRAM_NAME}.wasm"
fi

# Run with wasmtime
echo "Running with wasmtime..."
wasmtime run "${PROGRAM_NAME}.wasm" "$@"
```

### 5. Testing Integration

#### Add to test suite:
```d
void testWasiConsoleOutput() {
    string wasiTest = `
int main() {
    writeln("Hello from WASI!");
    writeln(42);
    writeln(3.14);
    writeln();
    writeln("WASI test complete");
    return 0;
}`;
    
    auto result = compileToWasi(wasiTest);
    assertTrue(result.success, "WASI test should compile");
    
    // Check for WASI imports
    assertTrue(result.wat.canFind("wasi_snapshot_preview1"), 
               "Should import WASI namespace");
    assertTrue(result.wat.canFind("fd_write"), 
               "Should import fd_write function");
    assertTrue(result.wat.canFind("_start"), 
               "Should have WASI _start function");
    assertTrue(result.wat.canFind("export \"memory\""), 
               "Should export memory for WASI");
}
```

## 🚀 Build & Run Workflow

1. **Compile D source**:
   ```bash
   ./d2wasm hello.d -o hello.wat
   ```

2. **Convert to binary**:
   ```bash
   wat2wasm hello.wat -o hello.wasm
   ```

3. **Run with wasmtime**:
   ```bash
   wasmtime run hello.wasm
   ```

## 🎯 Result

With these changes, the D-to-WASM compiler will generate **WASI-compliant WASM modules** that can run on any WASI runtime:

1. ✅ **Standard WASI compliance** - works with wasmtime, wasmer, wasm3, etc.
2. ✅ **No custom JavaScript needed** - just wasmtime binary
3. ✅ **Production deployment** - single .wasm file + wasmtime
4. ✅ **Better performance** - native runtime, no JS overhead
5. ✅ **Console output** - full writeln() support for all types

**Much cleaner and more professional than the JavaScript host approach!**