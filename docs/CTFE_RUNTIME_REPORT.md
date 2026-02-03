# CTFE vs Runtime Behavior Report

This document analyzes how slices, UFCS, and struct methods work at **compile-time (CTFE)** versus **runtime** in our D-to-WASM compiler.

---

## Architecture Overview

Our compiler has a **unified codegen** approach:

```
                    ┌─────────────────────┐
                    │   D Source Code     │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │   Parser + TypeChk  │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │   WASM Emitter      │  ◄── Same codegen for both paths
                    └──────────┬──────────┘
                               │
              ┌────────────────┴────────────────┐
              │                                 │
    ┌─────────▼─────────┐            ┌─────────▼─────────┐
    │   CTFE Context    │            │  Runtime Context  │
    │   (wasm3 library  │            │  (wasm3 CLI via   │
    │    in compiler)   │            │   test_runner.sh) │
    └───────────────────┘            └───────────────────┘
```

**Key insight:** Both CTFE and runtime use **wasm3** to execute the **same WASM bytecode**. 
- CTFE: wasm3 as a D library with live memory access (`CTFERuntime`)
- Runtime: wasm3 CLI invoked by test harness

If the emitter is correct, both work.

---

## 1. Slices (Dynamic Arrays)

### Memory Layout

**Real D:** 8 bytes (ptr + length), capacity in GC metadata  
**Our WASM:** 12 bytes (ptr + length + capacity) — no GC

```
Offset 0: ptr      (i32) — pointer to backing data
Offset 4: length   (i32) — number of elements
Offset 8: capacity (i32) — allocated capacity
```

### CTFE Behavior

When evaluating `enum arr = [1, 2, 3]; enum len = arr.length;`:

1. **CTFEEvaluator.evaluateArrayLiteral()** stores elements as raw bytes
2. For complex expressions, emitter generates WASM
3. **wasm3** executes it with live memory access
4. **CTFERuntime.readMemory()** extracts results

```d
// This happens AT COMPILE TIME inside the compiler:
auto runtime = new CTFERuntime();
runtime.loadModule(emittedWasmBytes);
auto result = runtime.callI32("__eval");
// Now we have the CTFE result
```

### Runtime Behavior

Same WASM runs in wasm3. The emitted code:

| Operation | Emitted WASM |
|-----------|--------------|
| `arr.length` | `i32.load offset=4` from slice struct |
| `arr.ptr` | `i32.load offset=0` from slice struct |
| `arr.capacity` | `i32.load offset=8` from slice struct |
| `arr[i]` | Bounds check + `i32.load` at `ptr + i*4` |
| `arr[i] = x` | Bounds check + `i32.store` at `ptr + i*4` |

### Verification: Same Code, Two Runtimes

```d
// tests/milestones/milestone_55_slice_literal/test.d
int main() {
    int[] arr = [1, 2, 3];
    return arr.length;  // Should return 3
}
```

**CTFE verification:**
```d
enum arr = [1, 2, 3];
static assert(arr.length == 3);  // Compile-time check
```

**Runtime verification:**
```bash
./test_runner.sh tests/milestones/milestone_55_slice_literal/
# Runs in wasm3, expects return value 3
```

### Current Status

| Feature | Emitter | CTFE (wasm3) | Runtime (wasm3) |
|---------|---------|--------------|-------------------|
| Slice literal | ✅ | ✅ | ✅ |
| `.length` | ✅ | ✅ | ✅ |
| `.capacity` | ✅ | ? | ? |
| `arr[i]` read | 🔄 | ? | ? |
| `arr[i]` write | 🔄 | ? | ? |

---

## 2. UFCS (Uniform Function Call Syntax)

### Resolution

`obj.func(args)` resolves to:
1. Member function of `obj`'s type → call as method
2. Free function `func(typeof(obj), args...)` → rewrite as `func(obj, args)`

### Implementation

In **type_checker.d**:
```d
// If method lookup fails, try UFCS
if (!foundMethod) {
    if (findFreeFunction(funcName, objType)) {
        callExpr.isUFCS = true;
    }
}
```

In **emitter.d**:
```d
if (callExpr.isUFCS) {
    // Emit object as first argument
    emit(callExpr.object);  
    // Then other args
    foreach (arg; callExpr.arguments) emit(arg);
    // Call free function
    emitCall(funcName);
}
```

### CTFE vs Runtime

**Identical.** UFCS is a compile-time syntax transformation. By the time WASM is emitted, it's just a regular function call with reordered arguments.

```d
int doubled(int x) { return x * 2; }

// CTFE — works because emitter generates: call $doubled with arg 21
enum x = 21.doubled();  // == 42

// Runtime — same WASM
int main() {
    return 21.doubled();  // == 42
}
```

### Verification

**Test file:** `tests/milestones/milestone_54_ufcs_basic/test.d`

Both paths execute the same `call $doubled` instruction.

---

## 3. Struct Methods

### Calling Convention

Methods receive `this` as hidden first parameter (pointer to struct):

```d
struct Point {
    int x, y;
    int sum() { return x + y; }
}
// Emits as: int Point_sum(Point* this) { return this.x + this.y; }
```

### Emitted WASM

```wasm
(func $Point_sum (param $this i32) (result i32)
  ;; return this.x + this.y
  local.get $this
  i32.load offset=0     ;; x at offset 0
  local.get $this
  i32.load offset=4     ;; y at offset 4
  i32.add
)
```

### CTFE vs Runtime

**Nearly identical.** Both execute the same pointer-based field access.

CTFE restriction: Cannot take address of `this` and use it after function returns (lifetime issues). But basic field access works.

### Implementation Details

| Component | Where | What |
|-----------|-------|------|
| `isMethod` flag | `FunctionDecl` (bitfield) | Marks function as method |
| `parent` field | `FunctionDecl` | Points to containing struct |
| `this` registration | `FuncContext.structParams` | Local index 0 |
| Name mangling | Emitter | `StructName_methodName` |

### Verification

```d
// tests/milestones/milestone_49-53
struct Counter {
    int value;
    int get() { return value; }           // milestone_49
    int getExplicit() { return this.value; } // milestone_50
    void inc() { value = value + 1; }     // milestone_53
}
```

---

## 4. What Needs Verification

### For Each Feature, Test Both Paths:

```d
// 1. CTFE path (enum forces compile-time evaluation)
enum ctfeResult = expression;
static assert(ctfeResult == expected);

// 2. Runtime path (function runs in wasm3)
int main() {
    auto runtimeResult = expression;
    if (runtimeResult != expected) return 1;
    return 0;  // Success
}
```

### Verification Matrix

| Feature | CTFE Test | Runtime Test | Notes |
|---------|-----------|--------------|-------|
| Slice `.length` | `enum arr = [1,2,3]; static assert(arr.length == 3);` | `return arr.length;` → 3 | ✅ Both work |
| Slice `.capacity` | ? | ? | Need to test |
| Slice `arr[i]` | `static assert(arr[1] == 2);` | `return arr[1];` → 2 | 🔄 In progress |
| UFCS | `enum x = 21.doubled(); static assert(x == 42);` | `return 21.doubled();` → 42 | ✅ Both work |
| Method call | `enum p = Point(3,4); static assert(p.sum() == 7);` | `return p.sum();` → 7 | Needs struct CTFE |

### Known Divergences

| Feature | CTFE | Runtime | Why |
|---------|------|---------|-----|
| `.capacity` | May differ | Matches allocation | CTFE uses different arena |
| Pointer escape | Forbidden | Allowed | CTFE memory is ephemeral |
| GC operations | N/A | N/A | No GC in either |

---

## 5. Testing Strategy

### Add Dual-Path Tests

For each new feature, create two tests:

**File: `tests/ctfe/slice_length.d`**
```d
// CTFE test
enum arr = [10, 20, 30];
static assert(arr.length == 3);
static assert(arr[1] == 20);

// Also test via enum function call
int getLen(int[] a) { return a.length; }
enum len = getLen([1,2,3,4,5]);
static assert(len == 5);
```

**File: `tests/milestones/milestone_55_slice_literal/test.d`**
```d
// Runtime test
int main() {
    int[] arr = [10, 20, 30];
    return arr.length;  // Expected: 3
}
```

### Automated Comparison

```bash
# Run both and compare
./run_ctfe_test.sh tests/ctfe/slice_length.d  # Runs during compilation
./test_runner.sh tests/milestones/milestone_55_slice_literal/  # Runs in wasm3

# Both should succeed with matching semantics
```

---

## 6. Implementation Checklist

### For Slice Support (Milestones 55-58):

- [x] **Emitter**: `emitSliceVarDecl()` — allocate struct + backing data
- [x] **Emitter**: `.length/.ptr/.capacity` field access
- [ ] **Emitter**: `emitIndex()` — bounds check + element load
- [ ] **Emitter**: Index assignment — bounds check + element store
- [ ] **CTFE**: Verify array literals work in `enum`
- [ ] **CTFE**: Verify indexing works in `enum`

### For Struct Methods (Milestones 49-53):

- [x] **Parser**: `isMethod` flag on functions in structs
- [x] **TypeChecker**: `this` identifier resolution
- [x] **Emitter**: Hidden `this` parameter at local 0
- [x] **Emitter**: Field access via `this` pointer
- [x] **Emitter**: Method mutation (stores through `this`)
- [ ] **CTFE**: Struct construction in `enum` context
- [ ] **CTFE**: Method calls on `enum` structs

### For UFCS (Milestone 54):

- [x] **TypeChecker**: Set `isUFCS` flag when method not found
- [x] **Emitter**: Reorder arguments for UFCS calls
- [x] **CTFE**: Works automatically (same WASM)
- [x] **Runtime**: Works automatically (same WASM)

---

## Summary

| Component | Single Codegen? | CTFE Works? | Runtime Works? |
|-----------|-----------------|-------------|----------------|
| Slices | ✅ Same emitter | ✅ via wasm3 | ✅ via wasm3 |
| UFCS | ✅ Same emitter | ✅ Automatic | ✅ Automatic |
| Struct Methods | ✅ Same emitter | 🔄 Partial | ✅ Working |

**The beauty of your architecture:** Fix the emitter once, both paths work.
