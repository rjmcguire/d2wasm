---
name: Arena Memory Safety Feature
description: Safe-by-default arena memory discipline — tracks arena-derived value lifetimes, prevents unsafe escapes, @escapes annotation, __arena_new()/__arena_drop() sub-generations
type: project
---

Arena memory safety feature — in progress as of 2026-03-17.

**Milestones 1-6 implemented** (parsing, taint analysis, safety checks, @escapes suppression, sub-generations, use-after-free detection):
- `src/semantic/arena_taint.d` — new module: taint analysis + safety checks + generation tracking
- `src/ast/nodes.d` — `escapesParams` field on DeclAttrs and FunctionDecl, `isRef` on Parameter
- `src/parser/tree_sitter_bridge.d` — `@escapes("param")` and `ref` parameter parsing
- `src/main.d` — `--arena-safety` CLI flag, `ArenaSafetyError` in catch chain

**Currently implementing: `ref` parameters** across all backends (WASM, native, native-jit).

**Why:** User wants safe-by-default arena memory model. `ref` params needed for proper arena safety tests and general D language support.

**How to apply:** Gate arena safety behind `--arena-safety` flag. Test cases in `tests/milestones/quality_52-59_*`, `tests/ctfe_parity/parity_126-132_*`, `tests/output_parity/output_070-073_*`.
