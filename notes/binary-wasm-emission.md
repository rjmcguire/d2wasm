# Direct Binary WASM Emission

## Motivation

Currently the compiler generates WAT (WebAssembly Text Format) and relies on external `wat2wasm` for binary conversion. For CTFE and self-contained operation, we should emit binary WASM directly.

## Binary WASM Structure

### Header
```
Bytes 0-3:   0x00 0x61 0x73 0x6D  (magic: "\0asm")
Bytes 4-7:   0x01 0x00 0x00 0x00  (version: 1)
```

### Sections
After the header, the module consists of sections. Each section:
```
1 byte:      Section ID
LEB128:      Section size in bytes
N bytes:     Section content
```

### Section IDs
```
0:  Custom section (name, debugging info)
1:  Type section (function signatures)
2:  Import section
3:  Function section (function type indices)
4:  Table section
5:  Memory section
6:  Global section
7:  Export section
8:  Start section
9:  Element section
10: Code section (function bodies)
11: Data section
```

## Minimal WASM Module

A minimal module with one function `add(i32, i32) -> i32`:

```
0000: 00 61 73 6d              ; magic
0004: 01 00 00 00              ; version 1

; Type section (id=1)
0008: 01                       ; section id
0009: 07                       ; section size (7 bytes)
000a: 01                       ; 1 type
000b: 60                       ; func type
000c: 02                       ; 2 params
000d: 7f                       ; i32
000e: 7f                       ; i32
000f: 01                       ; 1 result
0010: 7f                       ; i32

; Function section (id=3)
0011: 03                       ; section id
0012: 02                       ; section size (2 bytes)
0013: 01                       ; 1 function
0014: 00                       ; type index 0

; Export section (id=7)
0015: 07                       ; section id
0016: 07                       ; section size (7 bytes)
0017: 01                       ; 1 export
0018: 03                       ; name length
0019: 61 64 64                 ; "add"
001c: 00                       ; export kind (function)
001d: 00                       ; function index 0

; Code section (id=10)
001e: 0a                       ; section id
001f: 09                       ; section size (9 bytes)
0020: 01                       ; 1 function body
0021: 07                       ; body size (7 bytes)
0022: 00                       ; 0 local declarations
0023: 20 00                    ; local.get 0
0025: 20 01                    ; local.get 1
0027: 6a                       ; i32.add
0028: 0b                       ; end
```

Total: 41 bytes for a working add function.

## D Implementation

### Core Types

```d
module wasm.binary;

/// WASM value types
enum WasmType : ubyte {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    funcref = 0x70,
    externref = 0x6F,
}

/// WASM section IDs
enum SectionId : ubyte {
    custom = 0,
    type = 1,
    import_ = 2,
    function_ = 3,
    table = 4,
    memory = 5,
    global = 6,
    export_ = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
}

/// Export kinds
enum ExportKind : ubyte {
    func = 0,
    table = 1,
    memory = 2,
    global = 3,
}
```

### LEB128 Encoding

```d
/// Encode unsigned LEB128
void writeLEB128U(ref Appender!(ubyte[]) output, ulong value) {
    do {
        ubyte b = cast(ubyte)(value & 0x7F);
        value >>= 7;
        if (value != 0) b |= 0x80;
        output ~= b;
    } while (value != 0);
}

/// Encode signed LEB128  
void writeLEB128S(ref Appender!(ubyte[]) output, long value) {
    bool more = true;
    while (more) {
        ubyte b = cast(ubyte)(value & 0x7F);
        value >>= 7;
        if ((value == 0 && !(b & 0x40)) || (value == -1 && (b & 0x40))) {
            more = false;
        } else {
            b |= 0x80;
        }
        output ~= b;
    }
}
```

### Binary Emitter

```d
class WasmBinaryEmitter {
    private Appender!(ubyte[]) output;
    
    // Collected data for each section
    private FuncType[] types;
    private FuncDecl[] functions;
    private Export[] exports;
    private FuncBody[] bodies;
    
    /// Start a new module
    void beginModule() {
        output.clear();
        // Magic number
        output ~= [0x00, 0x61, 0x73, 0x6D];
        // Version 1
        output ~= [0x01, 0x00, 0x00, 0x00];
    }
    
    /// Add a function type
    uint addType(WasmType[] params, WasmType[] results) {
        types ~= FuncType(params.dup, results.dup);
        return cast(uint)(types.length - 1);
    }
    
    /// Add a function
    uint addFunction(uint typeIndex) {
        functions ~= FuncDecl(typeIndex);
        return cast(uint)(functions.length - 1);
    }
    
    /// Add an export
    void addExport(string name, ExportKind kind, uint index) {
        exports ~= Export(name, kind, index);
    }
    
    /// Add function body
    void addBody(uint funcIndex, WasmType[] locals, ubyte[] code) {
        bodies ~= FuncBody(funcIndex, locals.dup, code.dup);
    }
    
    /// Finalize and get binary
    ubyte[] finalize() {
        // Write type section
        writeTypeSection();
        // Write function section
        writeFunctionSection();
        // Write export section
        writeExportSection();
        // Write code section
        writeCodeSection();
        
        return output.data.dup;
    }
    
    private void writeSection(SectionId id, ubyte[] content) {
        output ~= cast(ubyte)id;
        writeLEB128U(output, content.length);
        output ~= content;
    }
    
    private void writeTypeSection() {
        if (types.length == 0) return;
        
        Appender!(ubyte[]) section;
        writeLEB128U(section, types.length);  // type count
        
        foreach (t; types) {
            section ~= 0x60;  // func type marker
            writeLEB128U(section, t.params.length);
            foreach (p; t.params) section ~= cast(ubyte)p;
            writeLEB128U(section, t.results.length);
            foreach (r; t.results) section ~= cast(ubyte)r;
        }
        
        writeSection(SectionId.type, section.data);
    }
    
    private void writeFunctionSection() {
        if (functions.length == 0) return;
        
        Appender!(ubyte[]) section;
        writeLEB128U(section, functions.length);
        
        foreach (f; functions) {
            writeLEB128U(section, f.typeIndex);
        }
        
        writeSection(SectionId.function_, section.data);
    }
    
    private void writeExportSection() {
        if (exports.length == 0) return;
        
        Appender!(ubyte[]) section;
        writeLEB128U(section, exports.length);
        
        foreach (e; exports) {
            // Write name
            writeLEB128U(section, e.name.length);
            section ~= cast(ubyte[])e.name;
            // Write kind and index
            section ~= cast(ubyte)e.kind;
            writeLEB128U(section, e.index);
        }
        
        writeSection(SectionId.export_, section.data);
    }
    
    private void writeCodeSection() {
        if (bodies.length == 0) return;
        
        Appender!(ubyte[]) section;
        writeLEB128U(section, bodies.length);
        
        foreach (b; bodies) {
            // Build function body
            Appender!(ubyte[]) body;
            
            // Local declarations (simplified: no compression)
            writeLEB128U(body, b.locals.length);
            foreach (l; b.locals) {
                writeLEB128U(body, 1);  // count
                body ~= cast(ubyte)l;   // type
            }
            
            // Code
            body ~= b.code;
            body ~= 0x0B;  // end opcode
            
            // Write body with size prefix
            writeLEB128U(section, body.data.length);
            section ~= body.data;
        }
        
        writeSection(SectionId.code, section.data);
    }
}
```

## WASM Opcodes Reference

### Control Flow
```
0x00  unreachable
0x01  nop
0x02  block
0x03  loop
0x04  if
0x05  else
0x0B  end
0x0C  br (label)
0x0D  br_if (label)
0x0F  return
0x10  call (func_idx)
```

### Variable Access
```
0x20  local.get (idx)
0x21  local.set (idx)
0x22  local.tee (idx)
0x23  global.get (idx)
0x24  global.set (idx)
```

### Constants
```
0x41  i32.const (LEB128 signed)
0x42  i64.const (LEB128 signed)
0x43  f32.const (4 bytes little-endian)
0x44  f64.const (8 bytes little-endian)
```

### i32 Operations
```
0x45  i32.eqz
0x46  i32.eq
0x47  i32.ne
0x48  i32.lt_s
0x49  i32.lt_u
0x4A  i32.gt_s
0x4B  i32.gt_u
0x4C  i32.le_s
0x4D  i32.le_u
0x4E  i32.ge_s
0x4F  i32.ge_u

0x6A  i32.add
0x6B  i32.sub
0x6C  i32.mul
0x6D  i32.div_s
0x6E  i32.div_u
0x6F  i32.rem_s
0x70  i32.rem_u
0x71  i32.and
0x72  i32.or
0x73  i32.xor
0x74  i32.shl
0x75  i32.shr_s
0x76  i32.shr_u
```

### Memory Operations
```
0x28  i32.load (align, offset)
0x29  i64.load
0x2A  f32.load
0x2B  f64.load
0x36  i32.store
0x37  i64.store
0x38  f32.store
0x39  f64.store
```

## Migration Path

### Step 1: Parallel Implementation
Keep WAT generation, add binary emission as alternative path.

```d
// In compiler main:
if (emitBinary) {
    auto binary = wasmBinaryEmitter.finalize();
    std.file.write(outputPath, binary);
} else {
    auto wat = wasmGenerator.generate();
    std.file.write(outputPath ~ ".wat", wat);
    executeShell("wat2wasm ...");
}
```

### Step 2: Validation
Compare outputs:
1. Generate WAT, convert with wat2wasm
2. Generate binary directly
3. Compare byte-for-byte (or at least functional equivalence)

### Step 3: CTFE Integration
Use binary emission for CTFE (no external tools needed):

```d
// In CTFE executor:
auto wasmBytes = compiler.emitBinary(ctfeFunction);
auto result = wasm3Executor.run(wasmBytes, "ctfeFunction", args);
```

### Step 4: Deprecate WAT Path (Optional)
Once binary emission is stable, WAT generation becomes optional (debugging only).

## Testing

### Unit Tests
```d
unittest {
    auto emitter = new WasmBinaryEmitter();
    emitter.beginModule();
    
    // Add: (i32, i32) -> i32
    auto typeIdx = emitter.addType([WasmType.i32, WasmType.i32], [WasmType.i32]);
    auto funcIdx = emitter.addFunction(typeIdx);
    emitter.addExport("add", ExportKind.func, funcIdx);
    emitter.addBody(funcIdx, [], [
        0x20, 0x00,  // local.get 0
        0x20, 0x01,  // local.get 1
        0x6A,        // i32.add
    ]);
    
    auto binary = emitter.finalize();
    
    // Validate with wasm3
    auto executor = new CTFEExecutor();
    assert(executor.loadModule(binary));
    auto result = executor.execute("add", [5, 3]);
    assert(result.success);
    assert(result.i32Value == 8);
}
```

### Integration Tests
```d
// Full pipeline: D source -> binary WASM -> execution
auto source = "int add(int a, int b) { return a + b; }";
auto ast = parser.parse(source);
auto wasmBytes = compiler.emitBinary(ast);
auto result = executor.run(wasmBytes, "add", [10, 20]);
assert(result.i32Value == 30);
```

## Validation Strategy

Instead of depending on `wat2wasm` for building, use `wasm2wat` for validating.

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   D Source      │ ──► │  Binary WASM    │ ──► │    wasm3        │
│                 │     │  (our output)   │     │  (functional)   │
└─────────────────┘     └────────┬────────┘     └─────────────────┘
                                 │
                                 ▼
                        ┌─────────────────┐
                        │   wasm2wat      │
                        │  (decompile)    │
                        └────────┬────────┘
                                 │
                                 ▼
                        ┌─────────────────┐
                        │   Inspect WAT   │
                        │  (structural)   │
                        └─────────────────┘
```

**Validation layers:**
1. **wasm3 execution** — Does it run? Does it produce correct results?
2. **wasm2wat decompilation** — Is the structure valid? Can wabt parse it?
3. **WAT inspection/diff** — Does the decompiled output match expectations?

**Benefits:**
- No external build dependencies (fully self-contained compiler)
- Two independent validators (wasm3 + wabt)
- Decompiled WAT useful for debugging emission bugs
- Can diff decompiled WAT against expected output for regression tests

**Test script example:**
```bash
#!/bin/bash
# validate_wasm.sh - validate binary WASM output

WASM_FILE=$1
EXPECTED_WAT=$2

# 1. Functional test with wasm3
wasm3 --func main "$WASM_FILE"
if [ $? -ne 0 ]; then
    echo "FAIL: wasm3 execution failed"
    exit 1
fi

# 2. Structural test - can wabt parse it?
wasm2wat "$WASM_FILE" -o /tmp/decompiled.wat
if [ $? -ne 0 ]; then
    echo "FAIL: wasm2wat decompilation failed"
    exit 1
fi

# 3. Optional: diff against expected
if [ -n "$EXPECTED_WAT" ]; then
    diff -u "$EXPECTED_WAT" /tmp/decompiled.wat
    if [ $? -ne 0 ]; then
        echo "WARN: WAT differs from expected (may be OK if semantically equivalent)"
    fi
fi

echo "PASS: WASM validated"
```

## References

- WebAssembly Binary Format: https://webassembly.github.io/spec/core/binary/
- WASM Opcodes: https://webassembly.github.io/spec/core/binary/instructions.html
- LEB128: https://en.wikipedia.org/wiki/LEB128
- wabt (wat2wasm, wasm2wat): https://github.com/WebAssembly/wabt
