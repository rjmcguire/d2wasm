# Host Function Architecture

## Overview

Three tiers of "external" functions, each with different binding mechanisms:

```
┌─────────────────────────────────────────────────────────────┐
│  Tier 1: Compiler Intrinsics                                │
│  ─────────────────────────────                              │
│  Built into the compiler. No declaration needed.            │
│  Available at CTFE only.                                    │
│                                                             │
│  Examples: __writeln, __text, __ctfe                        │
│  Binding: Hardcoded in D compiler source                    │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Tier 2: CTFE Host Functions                                │
│  ──────────────────────────                                 │
│  Provided by compiler during CTFE execution.                │
│  Declared in D source, implemented in compiler.             │
│                                                             │
│  Examples: arena_alloc, memory introspection                │
│  Binding: wasm3 host function binding                       │
│  Declaration: extern(CTFE) or @ctfe attribute               │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Tier 3: Runtime Imports                                    │
│  ─────────────────────────                                  │
│  Provided by WASM host environment at runtime.              │
│  Declared in D source, implemented externally.              │
│                                                             │
│  Examples: console_log, DOM APIs, system calls              │
│  Binding: WASM import section                               │
│  Declaration: extern(WASM, "module_name")                   │
└─────────────────────────────────────────────────────────────┘
```

---

## Tier 1: Compiler Intrinsics

### Current State
Already implemented. Special-cased by name in the compiler.

### Intrinsics

| Name | Purpose | CTFE | Runtime |
|------|---------|------|---------|
| `__writeln(args...)` | Print during compilation | ✓ | ✗ |
| `__text(expr)` | Convert value to string | ✓ | ✗ |
| `__ctfe` | True if evaluating at compile time | ✓ | ✗ (false) |

### Implementation
- Recognized by name in CTFE evaluator
- No WASM code generated
- Functions containing only intrinsics are omitted from output

### No Changes Needed
This tier works. Leave it alone.

---

## Tier 2: CTFE Host Functions

### Purpose
More complex operations during CTFE that benefit from host implementation:
- Memory management (arena allocation)
- String operations beyond simple concat
- File I/O during compilation (string imports)
- Debugging/introspection

### Declaration Syntax

**Option A: Attribute-based**
```d
@ctfe extern int arena_alloc(int size);
@ctfe extern void arena_push();
@ctfe extern void arena_pop();
```

**Option B: Linkage specification**
```d
extern(CTFE) int arena_alloc(int size);
extern(CTFE) void arena_push();
```

**Option C: Magic module**
```d
import __ctfe_runtime;  // Compiler provides this implicitly

void foo() {
    auto ptr = __ctfe_runtime.alloc(100);
}
```

**Recommendation: Option C (magic module)**

Rationale:
- No new syntax needed
- Clear namespacing
- Compiler can provide different "modules" for different purposes
- Similar to how D's `object` module is implicitly available

### WASM Representation

During CTFE, these become WASM imports:

```wat
(import "__ctfe" "arena_alloc" (func $arena_alloc (param i32) (result i32)))
(import "__ctfe" "arena_push" (func $arena_push))
(import "__ctfe" "arena_pop" (func $arena_pop))
```

### Host Binding (wasm3)

```d
// In compiler's CTFE runtime
void bindCTFEFunctions(wasm3.Runtime runtime) {
    runtime.linkFunction("__ctfe", "arena_alloc", &hostArenaAlloc);
    runtime.linkFunction("__ctfe", "arena_push", &hostArenaPush);
    runtime.linkFunction("__ctfe", "arena_pop", &hostArenaPop);
}

extern(C) int hostArenaAlloc(int size) {
    return ctfeArena.alloc(size);
}
```

### Output Handling

Functions marked as CTFE-only:
- **CTFE path**: Emit as imports, wasm3 provides implementation
- **Runtime path**: Either error ("CTFE-only function called at runtime") or omit entirely

---

## Tier 3: Runtime Imports

### Purpose
Call external functions provided by the WASM host environment:
- Browser APIs (console, DOM, fetch)
- WASI (filesystem, clock, random)
- Custom host functions

### Declaration Syntax

**Option A: Linkage with module name**
```d
extern(WASM, "console") void log(int value);
extern(WASM, "env") int getTime();
```

**Option B: Attribute with module name**
```d
@wasmImport("console")
void log(int value);
```

**Option C: Module-level declaration**
```d
pragma(wasmImport, "console");

void log(int value);      // All extern functions in this scope → "console" module
void error(int value);
```

**Recommendation: Option A**

Rationale:
- Explicit per-function
- Similar to existing `extern(C)` syntax
- Clear what each function's origin is

### WASM Output

```d
// D source
extern(WASM, "console") void log(int value);
extern(WASM, "env") int getTime();

void main() {
    log(getTime());
}
```

Generates:

```wat
(import "console" "log" (func $console_log (param i32)))
(import "env" "getTime" (func $env_getTime (result i32)))

(func $main
    call $env_getTime
    call $console_log
)
```

### Import Section Emission

```d
// In emitter.d
void emitImportSection() {
    auto section = appender!(ubyte[])();
    
    leb128u(section, imports.length);
    
    foreach (imp; imports) {
        // Module name
        leb128u(section, imp.moduleName.length);
        section ~= cast(ubyte[])imp.moduleName;
        
        // Field name
        leb128u(section, imp.fieldName.length);
        section ~= cast(ubyte[])imp.fieldName;
        
        // Import kind (0 = function)
        section ~= 0x00;
        
        // Type index
        leb128u(section, imp.typeIndex);
    }
    
    emitSection(Section.import_, section.data);
}
```

### Type Handling

Import function types must be registered in the type section, just like regular functions:

```d
struct ImportInfo {
    string moduleName;
    string fieldName;
    uint typeIndex;      // Index into type section
    uint functionIndex;  // For calling
}
```

---

## Unified View

### Function Resolution Order

When the compiler sees a function call:

1. **Is it a Tier 1 intrinsic?** (`__writeln`, `__text`)
   - Yes → Handle directly in compiler, no codegen

2. **Is it declared as Tier 2 CTFE host function?**
   - Yes, and we're in CTFE → Emit import call, wasm3 handles
   - Yes, but at runtime → Error or substitute

3. **Is it declared as Tier 3 runtime import?**
   - Yes → Emit import, host provides at instantiation

4. **Is it a regular function?**
   - Yes → Emit call to local function

### Example: Mixed Usage

```d
import __ctfe_runtime;  // Magic module, Tier 2

extern(WASM, "console") void log(int value);  // Tier 3

enum computedValue = {
    // CTFE context
    auto buffer = __ctfe_runtime.alloc(100);  // Tier 2, wasm3 handles
    __writeln("Allocated buffer");             // Tier 1, compiler handles
    return 42;
}();

void main() {
    log(computedValue);  // Tier 3, runtime import
}
```

---

## Implementation Phases

### Phase 1: Runtime Imports (Tier 3)
1. Add `extern(WASM, "module")` parsing
2. Collect imports during semantic analysis
3. Emit import section before function section
4. Adjust function indices (imports come first)
5. Test with simple host function

### Phase 2: CTFE Host Functions (Tier 2)
1. Define `__ctfe_runtime` magic module
2. Bind host functions in wasm3
3. Emit imports in CTFE-generated modules
4. Implement arena allocation properly

### Phase 3: Expand Tier 1
1. Add `__ctfe` boolean
2. Consider `__traits` equivalent
3. File/string imports

---

## Resolved Design Decisions

### 1. Tier 3 imports during CTFE: **No**

CTFE must be deterministic — same source compiles the same way. Runtime imports (console, DOM, external services) are not available during CTFE.

- Tier 3 call during CTFE → Error: "runtime import 'X' not available at compile time"
- Compile-time I/O (file reads, config) → Tier 2 CTFE host functions

### 2. `__traits`: **Tier 1**

`__traits` is compiler introspection, not a function call. The compiler answers directly:
- `__traits(compiles, expr)` — can this expression compile?
- `__traits(allMembers, T)` — what members does this type have?

No WASM code generated, no host function — pure compiler magic.

### 3. Namespace collisions: **Error with guidance**

If user defines a name that conflicts with a magic module:
```
Error: 'alloc' conflicts with __ctfe_runtime.alloc
  hint: use 'import myalloc = mymodule;' to rename
```

D already supports `import newname = old.module;` renaming syntax.

### 4. WASI support: **Deferred, architecture supports it**

WASI is just a standard set of import names. Can add `import wasi;` magic module later as sugar over `extern(WASM, "wasi_snapshot_preview1")`.

No design changes needed — it's just another magic module when we want it.

## Remaining Open Questions

1. **Import function type signatures**
   - Need full signature in D declaration
   - Parser must extract param/return types

---

## Recommended First Milestone

**milestone_31_wasm_import**: Basic runtime import

```d
extern(WASM, "test") int get_value();

int result() {
    return get_value();
}
```

Test by providing a host function that returns 42. Verifies:
- Declaration parsing
- Import section emission
- Function index adjustment
- Call generation
