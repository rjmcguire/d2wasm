# Native CTFE Milestone Plan

## Goal

Add native ARM64 backend to the D compiler for **fast compile-time function evaluation (CTFE)** while keeping WASM as the output format.

## Why?

CTFE runs during every compile. Native execution is faster than wasm3 interpretation. This gives us faster compile times without changing the output format.

## Backend Modes

```
--backend=wasm        → WASM output + wasm3 CTFE (current default)
--backend=native      → WASM output + native CTFE (faster compiles!) ← target
--backend=native-only → Native output + native CTFE (future, not planned)
```

## Architecture

```
┌─────────────────────────────────────────┐
│            Frontend (unchanged)          │
│   Parser → AST → TypeChecker → SymbolTab │
└──────────────────┬──────────────────────┘
                   │
                   ▼
            ┌────────────┐
            │  Backend   │ ← interface in src/codegen/backend.d
            │ (abstract) │
            └─────┬──────┘
                  │
       ┌──────────┴──────────┐
       ▼                     ▼
┌─────────────┐       ┌─────────────┐
│ WASMBackend │       │NativeBackend│
│  (wasm3)    │       │(copy-patch) │
└──────┬──────┘       └──────┬──────┘
       │                     │
       ▼                     ▼
   WASM binary          ARM64 code
       │                     │
       └─────────┬───────────┘
                 │
            CTFE execution
```

## Key Design Decisions

1. **Stack-based operand model** — like WASM, for simplicity (can optimize later)
2. **Real stack for locals** — using ARM64 stack with prologue/epilogue
3. **Copy-and-patch codegen** — stencils extracted from LDC2, patched at runtime
4. **Tests via `--backend` flag** — same test files, different backend

## Project Layout

```
~/projects/d-to-wasm-compiler/
├── src/codegen/
│   ├── backend.d           # Backend interface + NativeBackend + WASMBackend
│   ├── native/
│   │   ├── arm64_codegen.d # NativeCodeGen struct (from copy-patch lib)
│   │   └── stencil_table.d # Generated stencils
│   ├── emitter.d           # WASM binary emitter
│   └── wasm.d              # WASM utilities

~/projects/copy-patch-arm64/         # Standalone library (reference/testing)
├── codegen.d               # NativeCodeGen struct
├── stencil_table.d         # Generated stencils (24 total)
├── stencils/source.d       # D source for stencils
├── extract_simple.d        # Mach-O parser, extracts stencils
├── test_codegen.d          # 35 tests (arithmetic, comparison, immediates)
├── test_branches.d         # 9 tests (B, CBZ, CBNZ, backward jumps)
├── test_calls.d            # 9 tests (BL, nested calls, arg preservation)
└── test_locals.d           # 7 tests (stack locals, survives calls)
```

## Milestones

### Phase 1: Backend Abstraction ✅ COMPLETE

| #  | Name              | Description                                      | Status |
|----|-------------------|--------------------------------------------------|--------|
| 80 | backend_interface | Extract Backend interface, WASM implements it    | ✅     |
| 81 | backend_factory   | `--backend=wasm\|native` flag, factory creates   | ✅     |

### Phase 2: Copy-Patch Foundation ✅ COMPLETE

| #  | Name               | Description                              | Tests |
|----|--------------------|------------------------------------------|-------|
| 82 | native_arithmetic  | add/sub/mul/div/mod stencils             | 10    |
| 83 | native_comparison  | eq/ne/lt/le/gt/ge stencils               | 15    |
| 84 | native_load_imm    | 32-bit immediate with hole patching      | 4     |
| 85 | native_memory      | load/store i32/i64 with offset           | 6     |
| 86 | native_branch      | B/CBZ/CBNZ, forward/backward, labels     | 9     |
| 87 | native_call        | BL, prologue/epilogue, nested calls      | 9     |
| 88 | native_stack_frame | Locals on real stack, survives calls     | 7     |

**Total: 60 tests passing in copy-patch library**

### Phase 3: Backend Integration ✅ COMPLETE

| #  | Name                        | Description                          | Status |
|----|-----------------------------|--------------------------------------|--------|
| 89 | native_backend_basic        | `return 42;` works via native CTFE   | ✅     |
| 90 | native_backend_variables    | Variables + expressions              | ✅     |
| 91 | native_backend_control_flow | if/else, while loops                 | ✅     |

Native backend now has parity with WASM backend for basic CTFE operations.

### Phase 3b: CTFE Feature Extension 🔶 IN PROGRESS

These milestones extend what CTFE can do, testing BOTH backends together.
Previously, structs/slices/function-calls only worked at runtime (WASM execution),
not at compile time (CTFE). These milestones add CTFE support and verify parity.

| #  | Name                  | Description                                         | Status |
|----|-----------------------|-----------------------------------------------------|--------|
| 92 | ctfe_structs          | CTFE can construct structs, access fields           | ⬜     |
| 93 | ctfe_slices           | CTFE can use slice operations                       | ⬜     |
| 94 | ctfe_function_calls   | CTFE can call other D functions                     | ⬜     |

Test pattern for these milestones:
```d
// Force CTFE via enum, then verify at runtime
enum result = someCTFEFunction();
int main() { return result; }
```

Both backends must produce the same result.

### Phase 4: CTFE Parity

| #  | Name              | Description                              | Status |
|----|-------------------|------------------------------------------|--------|
| 95 | native_ctfe_basic | `enum x = compute();` works              | ⬜     |
| 96 | native_ctfe_writeln | `__writeln` host function call         | ⬜     |
| 97 | native_ctfe_mixin | Mixin expansion via native CTFE          | ⬜     |

### Phase 5: Full Parity

| #  | Name                 | Description                                  | Status |
|----|----------------------|----------------------------------------------|--------|
| 98 | backend_parity_check | All 93+ tests pass with both backends        | ⬜     |

## Current State (2026-02-04)

**What works in BOTH backends for CTFE:**
- Literals (int, long, bool)
- Variables (declaration, access, assignment, compound assignment)
- Binary expressions (arithmetic, comparison, bitwise)
- Unary expressions (-x, !x)
- Control flow (if/else, while)
- Function parameters (up to 4)
- Return statements (including early returns)

**What doesn't work in CTFE (either backend):**
```d
struct Point { int x; int y; }
int test() {
    Point p = Point(10, 20);  // ❌ "Undefined identifier 'Point'"
    return p.x;
}

int helper() { return 42; }
int test2() {
    return helper();          // ❌ "Undefined identifier 'helper'"
}
```

These fail during CTFE type-checking, before reaching either backend.

## Next Steps (Milestone 92: ctfe_structs)

The issue is in the CTFE evaluator's symbol table/type checker, not the backends.
Need to investigate:

1. Why does CTFE type-checking fail to find struct types?
2. Why does CTFE type-checking fail to find other functions?
3. How does the WASM emitter handle these at runtime (for reference)?

The fix will likely be in `src/semantic/ctfe.d` — ensuring the type checker
used during CTFE compilation has access to all declarations.

## Stencil Regeneration

If stencils need updating:
```bash
cd ~/projects/copy-patch-arm64/stencils
ldc2 -O3 -c --frame-pointer=none -of=stencils.o source.d
cd ..
rdmd extract_simple.d stencils/stencils.o
# Creates stencil_table.d
```

Then copy to compiler:
```bash
cp stencil_table.d ~/projects/d-to-wasm-compiler/src/codegen/native/
cp codegen.d ~/projects/d-to-wasm-compiler/src/codegen/native/arm64_codegen.d
```

## Testing

```bash
# Compiler tests (93 passing)
cd ~/projects/d-to-wasm-compiler
rdmd run_tests.d

# With native backend
./d2wasm --backend=native -v /tmp/test.d

# Copy-patch library tests (60 passing)
cd ~/projects/copy-patch-arm64
rdmd test_codegen.d && rdmd test_branches.d && rdmd test_calls.d && rdmd test_locals.d
```

## Technical Notes

- **ARM64 only** — stencils are ARM64, WASM stays portable
- **No sandboxing** — native CTFE shares address space (we trust our codegen)
- **Instruction cache** — mprotect handles cache coherency on macOS
- **Hole markers** — 0xDEAD_0001, 0xDEAD_0002 for patching
- **MOV/MOVK encoding** — immediate in bits 5-20, mask 0xFFE0001F
