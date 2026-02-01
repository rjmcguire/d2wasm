# CTFE Memory Model and Error Handling

## Design Principles

1. **CTFE performance matters** — The "it doesn't need to be fast" argument is circular. People don't use CTFE heavily because it's slow, then claim it doesn't need to be fast. If CTFE were fast, it would enable new patterns.

2. **Keep templates simple/obvious** — Don't prematurely optimize, but don't paint into a corner. Simple implementations can be optimized later.

3. **Excellence in error messages** — This is non-negotiable. CTFE errors must show the complete path from evaluation site through execution to the error.

4. **Excellence in developer experience** — Especially during debugging and writing new code.

---

## Memory Model: Arena Allocation

### Why Arenas?

For CTFE, we don't need general-purpose malloc/free. CTFE evaluation is:
- **Bounded** — evaluation runs, produces a result, then everything is discarded
- **Hierarchical** — nested function calls create nested allocation scopes
- **Non-escaping** — CTFE memory doesn't persist past compile time

An arena allocator is perfect:
- Fast allocation (bump pointer)
- No fragmentation
- Trivial cleanup (reset the arena)
- Sub-arenas for nested scopes

### WASM Memory Layout for CTFE

```
WASM Linear Memory (1 page = 64KB minimum)
┌─────────────────────────────────────────────────────────────┐
│ 0x0000 - 0x00FF: Reserved (null pointer trap zone)         │
├─────────────────────────────────────────────────────────────┤
│ 0x0100 - 0x0FFF: Static data (string literals, etc.)       │
├─────────────────────────────────────────────────────────────┤
│ 0x1000 - onwards: Arena allocator space                    │
│                                                             │
│   ┌─────────────────────────────────────────────────────┐  │
│   │ Arena Header                                        │  │
│   │   - current_offset: u32                             │  │
│   │   - capacity: u32                                   │  │
│   │   - parent_arena: u32 (for sub-arenas)              │  │
│   ├─────────────────────────────────────────────────────┤  │
│   │ Allocation space (bump pointer)                     │  │
│   │   [obj1][obj2][obj3][................free........]  │  │
│   │                      ^                              │  │
│   │                      current_offset                 │  │
│   └─────────────────────────────────────────────────────┘  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Arena API (WASM imports)

We provide these as WASM imports that the generated CTFE code can call:

```wat
;; Allocate n bytes from current arena, returns pointer
(import "ctfe" "arena_alloc" (func $arena_alloc (param i32) (result i32)))

;; Push a new sub-arena (for function calls, scopes)
(import "ctfe" "arena_push" (func $arena_push))

;; Pop current sub-arena (on function return)
(import "ctfe" "arena_pop" (func $arena_pop))

;; Get current arena's remaining capacity
(import "ctfe" "arena_remaining" (func $arena_remaining (result i32)))
```

### Implementation in D (host side)

```d
/// Arena allocator for CTFE execution
struct CTFEArena {
    ubyte[] memory;      // Backing memory (WASM linear memory)
    uint offset;         // Current allocation offset
    uint capacity;       // Total capacity
    CTFEArena* parent;   // For sub-arena hierarchy
    
    /// Allocate n bytes, returns offset in linear memory
    uint alloc(uint size) {
        // Align to 8 bytes
        uint aligned = (offset + 7) & ~7;
        if (aligned + size > capacity) {
            return 0;  // Out of memory — will trigger CTFE error
        }
        uint ptr = aligned;
        offset = aligned + size;
        return ptr;
    }
    
    /// Create sub-arena for nested scope
    CTFEArena* push() {
        auto sub = cast(CTFEArena*)alloc(CTFEArena.sizeof);
        if (sub is null) return null;
        sub.memory = memory;
        sub.offset = offset;
        sub.capacity = capacity;
        sub.parent = &this;
        return sub;
    }
    
    /// Return to parent arena (discards all sub-allocations)
    CTFEArena* pop() {
        return parent;
    }
    
    /// Reset arena (for new CTFE evaluation)
    void reset() {
        offset = 0;
        parent = null;
    }
}
```

### Memory Limit for CTFE

CTFE should have a configurable memory limit to prevent runaway compile times:

```d
// Default: 16MB for CTFE
enum CTFE_MEMORY_LIMIT = 16 * 1024 * 1024;

// Configurable via compiler flag
// d2wasm --ctfe-memory=64MB source.d
```

If CTFE exceeds the limit, it's a compile error with a clear message:

```
error: CTFE memory limit exceeded (16MB)
  --> src/data.d:42:12
   |
42 | enum HUGE_TABLE = generateTable(1_000_000);
   |                   ^^^^^^^^^^^^^^^^^^^^^^^^
   |
help: increase CTFE memory limit with --ctfe-memory=SIZE
```

---

## Error Handling: Full Stack Traces

### Requirements

CTFE errors must show:
1. **Evaluation site** — Where in the source CTFE was triggered
2. **Execution stack** — The call chain through D functions
3. **Error location** — Exact source location where the error occurred
4. **Error type** — What went wrong (trap type, assertion failure, etc.)

### Example Output

```
error: CTFE evaluation failed: integer division by zero
  --> src/config.d:15:12
   |
15 | enum RATIO = calculateRatio(userCount, 0);
   |              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ CTFE evaluated here
   |
  CTFE execution trace:
   1: calculateRatio(100, 0)
        --> src/math.d:42:8
   2:   divide(100, 0)
        --> src/math.d:47:12
   3:     [i32.div_s trapped]
        --> src/math.d:52:16
         |
      52 |     return a / b;
         |              ^ division by zero
```

### Implementation: Source Mapping

We need to track the mapping from WASM locations back to D source locations.

#### During Code Generation

When emitting WASM, record source mappings:

```d
struct SourceMapping {
    uint wasmOffset;      // Byte offset in WASM code section
    uint wasmFuncIndex;   // Function index in WASM module
    string sourceFile;    // D source file
    uint sourceLine;      // Line number
    uint sourceColumn;    // Column number
}

class WasmBinaryEmitter {
    SourceMapping[] sourceMappings;
    
    void emitWithMapping(ubyte[] bytes, ASTNode node) {
        if (node.location.isValid) {
            sourceMappings ~= SourceMapping(
                currentOffset,
                currentFuncIndex,
                node.location.file,
                node.location.line,
                node.location.column
            );
        }
        emit(bytes);
    }
}
```

#### During CTFE Execution

When wasm3 returns an error or trap:

```d
CTFEResult executeCTFE(ubyte[] wasmBytes, SourceMapping[] mappings, 
                        string funcName, CTFEInvocationSite site) {
    // ... execute in wasm3 ...
    
    if (result !is null) {
        // Get wasm3 backtrace
        auto backtrace = m3_GetBacktrace(runtime);
        
        // Build error with full trace
        auto error = CTFEError(
            site: site,  // Where CTFE was triggered
            wasmError: result,
            trace: buildSourceTrace(backtrace, mappings)
        );
        
        return CTFEResult.error(error);
    }
}

SourceTrace[] buildSourceTrace(IM3BacktraceInfo bt, SourceMapping[] mappings) {
    SourceTrace[] trace;
    
    for (auto frame = bt.frames; frame !is null; frame = frame.next) {
        // Find source mapping for this WASM location
        auto mapping = findMapping(mappings, frame.moduleOffset, frame.function_);
        
        trace ~= SourceTrace(
            funcName: m3_GetFunctionName(frame.function_),
            file: mapping.sourceFile,
            line: mapping.sourceLine,
            column: mapping.sourceColumn
        );
    }
    
    return trace;
}
```

### CTFE Invocation Site Tracking

The compiler needs to track where CTFE was requested:

```d
struct CTFEInvocationSite {
    string file;
    uint line;
    uint column;
    string expression;  // "calculateRatio(userCount, 0)"
    CTFEContext context; // enum initializer, static if, template arg, etc.
}

enum CTFEContext {
    enumInitializer,
    staticIf,
    staticAssert,
    templateArgument,
    staticForeach,
    pragma_,
}
```

### Error Types

Map wasm3 traps to user-friendly error messages:

```d
string friendlyTrapMessage(const(char)* wasmError) {
    import core.stdc.string : strcmp;
    
    if (strcmp(wasmError, m3Err_trapDivisionByZero) == 0)
        return "integer division by zero";
    if (strcmp(wasmError, m3Err_trapIntegerOverflow) == 0)
        return "integer overflow";
    if (strcmp(wasmError, m3Err_trapOutOfBoundsMemoryAccess) == 0)
        return "out of bounds memory access (null pointer or buffer overrun)";
    if (strcmp(wasmError, m3Err_trapUnreachable) == 0)
        return "unreachable code executed (assertion failed?)";
    // ... etc
    
    return "execution error: " ~ fromStringz(wasmError);
}
```

### Assert and Enforce in CTFE

D's `assert` should work in CTFE and produce good errors:

```d
// In D source
int safeDivide(int a, int b) {
    assert(b != 0, "divisor cannot be zero");
    return a / b;
}

enum x = safeDivide(10, 0);  // Should show the assert message
```

Output:
```
error: CTFE assertion failed: "divisor cannot be zero"
  --> src/example.d:8:12
   |
 8 | enum x = safeDivide(10, 0);
   |          ^^^^^^^^^^^^^^^^^ CTFE evaluated here
   |
  CTFE execution trace:
   1: safeDivide(10, 0)
        --> src/example.d:2:5
         |
       2 |     assert(b != 0, "divisor cannot be zero");
         |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

Implementation: compile `assert` to WASM `unreachable` with a preceding call to an error-reporting import:

```wat
;; assert(b != 0, "divisor cannot be zero")
local.get $b
i32.const 0
i32.ne
if
else
  ;; Report assertion failure
  i32.const 42        ;; string offset: "divisor cannot be zero"
  i32.const 24        ;; string length
  i32.const 2         ;; source line
  i32.const 5         ;; source column
  call $ctfe_assert_fail
  unreachable
end
```

The `$ctfe_assert_fail` import stores the assertion info for the error message before the trap occurs.

---

## Integration with Compiler Pipeline

### CTFE Detection Points

The semantic analyzer identifies CTFE contexts:

```d
void analyzeDeclaration(Declaration decl) {
    if (auto enumDecl = cast(EnumDeclaration)decl) {
        if (enumDecl.initializer.needsCTFE()) {
            auto result = evaluateCTFE(
                enumDecl.initializer,
                CTFEInvocationSite(
                    enumDecl.location,
                    enumDecl.initializer.toString(),
                    CTFEContext.enumInitializer
                )
            );
            
            if (!result.success) {
                reportCTFEError(result.error);
                return;
            }
            
            // Substitute constant value
            enumDecl.resolvedValue = result.value;
        }
    }
}
```

### CTFE Compilation Unit

For each CTFE evaluation, we need to compile:
1. The target function
2. All functions it calls (transitive closure)
3. Runtime support (arena imports, assert handler)

```d
ubyte[] compileCTFEUnit(Expression expr) {
    // Find all functions needed for this expression
    auto functions = collectDependencies(expr);
    
    // Compile to WASM
    auto emitter = new WasmBinaryEmitter();
    emitter.addCTFEImports();  // arena_alloc, arena_push, etc.
    
    foreach (func; functions) {
        emitter.emitFunction(func);
    }
    
    // Add entry point for the expression
    emitter.emitCTFEEntryPoint(expr);
    
    return emitter.finalize();
}
```

---

## Testing Strategy

### Unit Tests for Error Handling

```d
unittest {
    // Division by zero should produce clear error
    auto result = testCTFE("enum x = 1 / 0;");
    assert(!result.success);
    assert(result.error.message.canFind("division by zero"));
    assert(result.error.site.line == 1);
}

unittest {
    // Assert failure should show assert message
    auto result = testCTFE(`
        int check(int x) { assert(x > 0, "must be positive"); return x; }
        enum y = check(-5);
    `);
    assert(!result.success);
    assert(result.error.message.canFind("must be positive"));
    assert(result.error.trace.length >= 2);  // check() and the assert
}

unittest {
    // Memory exhaustion should be clear
    auto result = testCTFE(`
        int[] huge() { 
            int[] arr;
            foreach (i; 0 .. 100_000_000) arr ~= i;
            return arr;
        }
        enum x = huge();
    `, memoryLimit: 1024 * 1024);  // 1MB limit
    assert(!result.success);
    assert(result.error.message.canFind("memory limit"));
}
```

### Integration Tests

```d
// Test that good CTFE works
unittest {
    auto result = testCTFE("enum fib10 = fibonacci(10);");
    assert(result.success);
    assert(result.value == 55);
}

// Test that errors propagate correctly through call chains
unittest {
    auto result = testCTFE(`
        int a() { return b(); }
        int b() { return c(); }
        int c() { return 1 / 0; }
        enum x = a();
    `);
    assert(!result.success);
    assert(result.error.trace.length == 3);
    assert(result.error.trace[0].funcName == "a");
    assert(result.error.trace[1].funcName == "b");
    assert(result.error.trace[2].funcName == "c");
}
```

---

## Summary

| Aspect | Approach |
|--------|----------|
| **Memory** | Arena allocator with sub-arenas for scopes |
| **Memory limit** | Configurable, default 16MB, clear error on exhaustion |
| **Error messages** | Full stack trace: evaluation site → call chain → error |
| **Source mapping** | Track WASM offsets → D source locations during codegen |
| **Trap handling** | Map wasm3 traps to friendly error messages |
| **Assert support** | Compile to unreachable + error reporting import |
| **Testing** | Unit tests for each error type, integration tests for traces |

The goal: when CTFE fails, the developer knows exactly what happened and where, without having to understand WASM internals.

---

## Implementation Boundary Errors

When we hit the edges of what the compiler supports, errors must be:
1. **Explicit** — never silent failure or wrong codegen
2. **Informative** — what construct, what parameters, why it failed
3. **Actionable** — workaround suggestions, or how to report for improvement

### Example: Unsupported Template

```
internal: template not found for construct
  construct: for_loop
  index_type: i128
  counter_local: $big_counter (index 254)
  
  --> src/heavy.d:142:5
   |
142|     for (cent i = 0; i < limit; i++) {
   |     ^^^
   
hint: i128/cent loops not yet implemented
      consider using i64 if value range permits
      
note: this is a compiler limitation, not a D language error
      report at: https://github.com/...
```

### Example: Local Index Overflow

```
internal: local index exceeds template capacity
  template: binary_op_i32
  local_index: 203
  template_capacity: 127 (1-byte LEB128)
  
  --> src/huge_function.d:891:12
   |
891|     result = tempVar + other;
   |              ^^^^^^^
   
note: function has 203 locals, exceeding fast-path template limit
      falling back to direct emission (slower but correct)
      
hint: consider refactoring to reduce local variable count
      or this may indicate a compiler optimization opportunity
```

### Boundary Handling Strategy

```d
Result!WasmBytes emitConstruct(Construct c, SourceLocation loc) {
    // Try to find a matching template
    auto tpl = findTemplate(c.kind, c.types);
    
    if (tpl is null) {
        // No template - explicit error with guidance
        return Result.error(TemplateNotFound(
            construct: c.kind,
            types: c.types,
            location: loc,
            hint: suggestWorkaround(c),
            reportUrl: ISSUE_TRACKER_URL
        ));
    }
    
    // Check if parameters fit template constraints
    if (!tpl.canHandle(c.params)) {
        // Parameters exceed template capacity
        if (ALLOW_FALLBACK) {
            // Emit warning, fall back to direct emission
            warn(TemplateFallback(tpl, c, loc));
            return emitDirect(c, loc);
        } else {
            return Result.error(TemplateOverflow(tpl, c, loc));
        }
    }
    
    // Happy path - use template
    return emitFromTemplate(tpl, c, loc);
}
```

### Why This Matters

1. **For development**: When we hit boundaries, we know exactly what to implement next
2. **For users**: Clear guidance instead of mysterious failures
3. **For prioritization**: Error frequency tells us which templates to add
4. **For correctness**: Never silently produce wrong code — fail loud or fall back safely
