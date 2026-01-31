# Console Output Integration Guide

## 🔧 Required Code Changes for Full Integration

### 1. Modify `src/codegen/wasm_generator.d`

#### Add Console Imports Method:
```d
/**
 * Add console function imports to the WASM module
 */
void addConsoleImports() {
    // Import console functions for different data types
    wasmModule.imports ~= "(import \"console\" \"log_i32\" (func $console_log_i32 (param i32)))";
    wasmModule.imports ~= "(import \"console\" \"log_f64\" (func $console_log_f64 (param f64)))";  
    wasmModule.imports ~= "(import \"console\" \"log_string\" (func $console_log_string (param i32)))";
    wasmModule.imports ~= "(import \"console\" \"log_newline\" (func $console_log_newline))";
}
```

#### Modify `generateModule()` method:
```d
WasmModule generateModule(Declaration[] declarations) {
    wasmModule = WasmModule();
    
    // Add console imports for writeln support
    addConsoleImports();
    
    // ... rest of existing code
}
```

#### Enhance `generateCallExpression()` method:
```d
void generateCallExpression(CallExpression expr) {
    // Get function name
    if (auto identExpr = cast(IdentifierExpression)expr.function_) {
        // Handle special console output functions
        if (identExpr.name == "writeln") {
            generateWritelnCall(expr);
            return;
        }
    }
    
    // ... existing function call code
}

/**
 * Generate writeln function call with type-specific console output
 */
void generateWritelnCall(CallExpression expr) {
    if (expr.arguments.length == 0) {
        // writeln() with no arguments - just print newline
        context.addInstruction("call $console_log_newline");
        return;
    }
    
    foreach (arg; expr.arguments) {
        if (auto literal = cast(LiteralExpression)arg) {
            generateWritelnArgument(literal);
        } else {
            // For non-literals, evaluate and determine type
            generateExpression(arg);
            // Use type information to call appropriate console function
            // TODO: Get actual type from semantic analysis
            context.addInstruction("call $console_log_i32");
        }
    }
    
    // Always add newline at end
    context.addInstruction("call $console_log_newline");
}

/**
 * Generate type-appropriate console output for literal
 */
void generateWritelnArgument(LiteralExpression literal) {
    import std.variant;
    
    if (literal.value.type == typeid(long)) {
        context.addInstruction(format("i32.const %d", literal.value.get!long));
        context.addInstruction("call $console_log_i32");
    } else if (literal.value.type == typeid(double)) {
        context.addInstruction(format("f64.const %f", literal.value.get!double));
        context.addInstruction("call $console_log_f64");
    } else if (literal.value.type == typeid(string)) {
        // Generate string ID and call string function
        uint stringId = registerStringLiteral(literal.value.get!string);
        context.addInstruction(format("i32.const %d", stringId));
        context.addInstruction("call $console_log_string");
    }
}
```

### 2. Add String Literal Management

#### Add to WasmGenerator class:
```d
private uint[string] stringLiterals;
private uint nextStringId = 1;

/**
 * Register string literal and return ID
 */
uint registerStringLiteral(string str) {
    auto existing = str in stringLiterals;
    if (existing) {
        return *existing;
    }
    
    uint id = nextStringId++;
    stringLiterals[str] = id;
    return id;
}

/**
 * Get registered string literals for runtime
 */
uint[string] getStringLiterals() {
    return stringLiterals;
}
```

### 3. Update `src/main.d`

#### Modify `compileFile()` to output string mappings:
```d
// After WASM generation:
auto wasmGenerator = new WasmGenerator(symbolTable);
auto wasmModule = wasmGenerator.generateModule(ast);

// Write WAT file
string watFile = setExtension(options.outputFile, ".wat");
std.file.write(watFile, wasmModule.toWAT());

// Write string literals JSON for runtime
string jsonFile = setExtension(options.outputFile, ".strings.json");
auto stringLiterals = wasmGenerator.getStringLiterals();
import std.json;
JSONValue jsonData = JSONValue(stringLiterals);
std.file.write(jsonFile, jsonData.toString());
```

### 4. Update Build Process

#### Create run script template:
```bash
#!/bin/bash
# Auto-generated runner for D-WASM program

PROGRAM_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Convert WAT to WASM if needed
if [ ! -f "${PROGRAM_NAME}.wasm" ] || [ "${PROGRAM_NAME}.wat" -nt "${PROGRAM_NAME}.wasm" ]; then
    wat2wasm "${PROGRAM_NAME}.wat" -o "${PROGRAM_NAME}.wasm"
fi

# Run with host runtime
node "${SCRIPT_DIR}/runtime/host.js" "${PROGRAM_NAME}.wasm" "$(cat "${PROGRAM_NAME}.strings.json")"
```

## 🧪 Testing Integration

### Add to test suite:
```d
// In tests/integration_tests.d
void testConsoleOutput() {
    string consoleTest = `
int main() {
    writeln("Hello, WASM!");
    writeln(42);
    writeln(3.14);
    return 0;
}`;
    
    // Test compilation
    auto result = compileString(consoleTest);
    assertTrue(result.success, "Console test should compile successfully");
    
    // Test WAT contains console imports
    string wat = result.wat;
    assertTrue(wat.canFind("console_log_i32"), "Should import i32 console function");
    assertTrue(wat.canFind("console_log_f64"), "Should import f64 console function");
    assertTrue(wat.canFind("console_log_string"), "Should import string console function");
    assertTrue(wat.canFind("console_log_newline"), "Should import newline console function");
}
```

## 📦 Runtime Distribution

### Package structure:
```
d2wasm-output/
├── program.wasm           # Compiled WASM binary
├── program.strings.json   # String literal mappings
├── runtime/
│   └── host.js           # JavaScript runtime
└── run.sh                # Execution script
```

### Installation:
1. Copy `runtime/host.js` to output directory
2. Generate string mappings during compilation
3. Create execution script with proper paths
4. Ensure `wat2wasm` is available or bundle converter

## 🎯 Result

With these changes, the D-to-WASM compiler will:

1. ✅ **Parse** `writeln()` calls in D source code
2. ✅ **Generate** appropriate WASM imports and function calls  
3. ✅ **Produce** runnable WASM with console output support
4. ✅ **Execute** via JavaScript host runtime
5. ✅ **Display** console output in terminal/browser

The implementation follows AGENTS.md principles with **clean separation of concerns** and **language construct templates** rather than algorithmic shortcuts.