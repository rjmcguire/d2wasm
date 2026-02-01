# D-to-WASM Compiler Architecture Summary

*Last updated: 2026-02-01*

## Vision

Build a full D compiler via an unconventional path:
- WASM as the trusted, rigorously-tested execution foundation
- CTFE via embedded WASM execution (wasm3)
- Validation by external tools (wasm3 for functional, wasm2wat for structural)
- Eventually: mixins via CTFE, self-hosting, optional native backends

## Core Architectural Decisions

### 1. Templates at Construct Level

Templates are **typed D language constructs**, not individual WASM instructions.

**Examples:**
- `for_loop_i32` — i32 for loop with counter, limit, body
- `if_else_i32` — if/else returning i32
- `binary_op_i32_add` — i32 addition
- `function_i32_i32_to_i32` — function signature pattern

**Why:**
- Matches D semantics, not WASM mechanics
- Better cache locality (larger memcpy, fewer calls)
- Type baked into template (correct opcodes, block signatures)

**Structure:**
```d
struct WasmTemplate {
    immutable(ubyte)[] bytes;      // Template bytes
    Hole[] holes;                   // Where to patch values
    MappingPoint[] mappingPoints;   // Source mapping locations
}

struct Hole {
    uint offset;
    HoleType type;  // local_index, func_index, block, constant, etc.
}
```

**Emission:**
```
D AST (typed) → Template selection → Memcpy + patch holes + splice blocks → Binary WASM
```

### 2. Binary WASM Emission (not WAT)

Generate binary WASM directly, skip WAT intermediate format.

**Why:**
- Self-contained (no wat2wasm dependency for build)
- Faster emission
- Same code path for CTFE and final output

**Validation:**
- wasm3 execution (functional correctness)
- wasm2wat decompilation (structural validity)
- Inverts dependency: validation tool, not build tool

### 3. Source Mapping via WASM Custom Sections

Embed source maps in the WASM binary itself.

**Format:**
```
Custom Section "sourcemap"
├── File table: [filenames...]
└── Mappings: [(wasmOffset, funcIndex, fileIndex, line, column), ...]
```

**Why:**
- Same mechanism for CTFE and final output
- Travels with the binary
- Standard WASM extension point

### 4. CTFE via wasm3

Compile-Time Function Execution uses embedded wasm3 interpreter.

**Why wasm3:**
- Pure C (easy D integration via existing bindings)
- Small (~100KB)
- Fast interpreter (sufficient for CTFE)
- No JIT complexity

**Flow:**
```
CTFE expression detected
    → Compile dependent functions to WASM
    → Load into wasm3
    → Execute
    → Capture result
    → Substitute into AST
```

### 5. Arena Allocation for CTFE Memory

**Why:**
- CTFE is bounded (evaluate, get result, discard)
- Hierarchical (nested function calls = nested scopes)
- Fast allocation (bump pointer)
- Trivial cleanup (reset arena)

**Interface:**
```d
arena_alloc(size) → offset
arena_push()      → create sub-arena
arena_pop()       → return to parent
```

### 6. Error Handling Philosophy

**For CTFE errors:**
- Full stack trace: evaluation site → call chain → error location
- Map WASM offsets back to D source locations
- Friendly messages (not raw WASM traps)

**For implementation boundaries:**
- Explicit errors when templates don't cover a case
- Never silent failure or wrong codegen
- Show: construct, types, parameters, why it failed
- Give: workarounds, how to report

```
internal: template not found for construct
  construct: for_loop
  index_type: i128
  
hint: i128 loops not yet implemented
note: this is a compiler limitation
```

## Design Principles

1. **CTFE performance matters** — "It doesn't need to be fast" is circular reasoning

2. **Excellence in error messages** — Non-negotiable. Users must understand what went wrong

3. **Excellence in developer experience** — Especially debugging and writing new code

4. **Keep templates simple/obvious** — So we CAN optimize later

5. **Explicit boundaries** — Know what's supported, fail clearly on what isn't

6. **Validation via external tools** — Don't trust only ourselves

## Deferred Decisions (Need Benchmarking)

1. **LEB128 handling in templates:**
   - Option A: Worst-case padding (5 bytes always)
   - Option B: Fast-path + fallback for large values
   - Option C: Template variants for different sizes

2. **Whether templates actually beat naive emission** — Need to measure

3. **Optimization passes** — Relying on WASM runtime for now

4. **Native code path** — WASM is the foundation; native can come later

## Implementation Phases

### Current: Foundation Complete
- [x] AST, parsing (tree-sitter-d)
- [x] Symbol table, type checking
- [x] Basic WAT generation
- [x] Design documentation

### Next: Binary Emission + CTFE
- [ ] Build minimal binary WASM emitter
- [ ] Create first construct-level templates
- [ ] Integrate wasm3 for CTFE execution
- [ ] Implement source mapping
- [ ] Test: D source → WASM → wasm3 execution → result

### Then: Expand Coverage
- [ ] More templates for D constructs
- [ ] Arena allocator integration
- [ ] Full error handling with stack traces
- [ ] Mixins via CTFE

### Later: Full D
- [ ] Remaining D language features
- [ ] Self-hosting
- [ ] Optimization passes (if needed)
- [ ] Native backends (if needed)

## File Map

```
notes/
├── architecture-summary.md      # This file
├── jit-research.md              # Background research on JIT paradigms
├── wasm3-ctfe-integration.md    # wasm3 embedding details
├── binary-wasm-emission.md      # Direct WASM generation
└── ctfe-memory-and-errors.md    # Arena allocation, error handling
```

## Key Insight

> "WASM gives us a base that is rigorously tested by others. If we went bare metal we would have a harder time validating."

The unconventional path (D → WASM → validate → eventually native) trades some performance ceiling for correctness confidence and incremental development.
