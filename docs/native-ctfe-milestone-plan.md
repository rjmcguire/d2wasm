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

### Phase 3: Backend Integration 🔶 IN PROGRESS

| #  | Name                        | Description                          | Status |
|----|-----------------------------|--------------------------------------|--------|
| 89 | native_backend_basic        | `return 42;` works via native CTFE   | ✅     |
| 90 | native_backend_arithmetic   | Variables + expressions              | ⬜     |
| 91 | native_backend_control_flow | if/else, while loops                 | ⬜     |
| 92 | native_backend_functions    | Multiple functions, calls            | ⬜     |
| 93 | native_backend_structs      | Struct layout, field access          | ⬜     |
| 94 | native_backend_slices       | Slice operations                     | ⬜     |

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

**What works in native backend:**
- Literals (int, long, bool)
- Binary expressions (arithmetic, comparison, bitwise)
- Unary expressions (-x, !x)
- Return statements

**What fails:**
```d
int compute() {
    int x = 42;   // ❌ VariableDeclaration not handled
    return x;     // ❌ IdentifierExpression throws "not yet supported"
}
```

## Next Steps (Milestone 90)

To support variables, need to add to `NativeCompiledFunction`:

1. **Local slot tracking:**
   ```d
   uint[string] localOffsets;  // variable name → stack offset
   uint nextLocalOffset = 0;
   ```

2. **Handle `VariableDeclaration` in `compileStatement()`:**
   ```d
   if (auto varDecl = cast(VariableDeclaration)stmt) {
       compileExpression(varDecl.initializer);
       localOffsets[varDecl.name] = nextLocalOffset;
       gen.emitStoreLocal32(nextLocalOffset);
       nextLocalOffset += 4;
   }
   ```

3. **Handle `IdentifierExpression` in `compileExpression()`:**
   ```d
   if (auto ident = cast(IdentifierExpression)expr) {
       uint offset = localOffsets[ident.name];
       gen.emitLoadLocal32(offset);
   }
   ```

4. **Handle `AssignmentExpression`:**
   ```d
   if (auto assign = cast(AssignmentExpression)expr) {
       compileExpression(assign.value);
       uint offset = localOffsets[assign.target.name];
       gen.emitStoreLocal32(offset);
   }
   ```

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
