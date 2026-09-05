# AGENTS.md

Instructions for humans and coding agents working in this repository.

This is **d2wasm**: a D-subset compiler targeting WebAssembly (and a native ARM64 backend). The compiler is written in D.

Read `DEVELOPMENT.md` before implementing features. The short version: **do not overfit tests**. Tests are examples of a general compiler, not a spec to pattern-match.

---

## Build

Requires: LDC (`ldc2`), DUB, gcc, libffi.

```bash
# first-time / after clone
git submodule update --init --recursive

dub build --compiler=ldc2
./d2wasm examples/fibonacci.d -o /tmp/fib.wasm
./d2wasm -r examples/fibonacci.d   # compile + run; exit code is the i32 result
```

`dub` runs `grammar/build.sh` and `runtime/build_ffi.sh` as pre-build steps. Those fetch/build tree-sitter if needed and compile the FFI trampoline.

On Linux, `libffi-dev` must be installed. Tree-sitter is built into `thirdparty/tree-sitter/` (gitignored); grammar `.a` files are produced under `grammar/tree-sitter-*/`.

macOS-only pieces (ObjC/Metal/FSEvents, `--link-framework`) live in the same tree but are versioned off on Linux. Do not add new unconditional macOS imports.

---

## Run

```
./d2wasm [options] input.d
```

Useful flags: `-r` / `--run` (compile and execute), `-v`/`-vv`/`-vvv`, `--print-ast`, `--validate-only`, `-t wasm|arm64-macos`, `-b wasm|native`, `--lsp`.

`--run` uses wasm3 in-process. Exit status of a successful run is the `i32` return of the entry function (default `main`).

---

## Tests

Primary loop (see `DEVELOPMENT.md`):

1. Run the milestone suite.
2. Fix the **first** failing test with a general implementation.
3. Re-run. Do not special-case the test source.

```bash
./test_runner.sh                  # milestones in order; stops on first failure
./test_runner.sh milestone_04     # filter by name substring
./test_runner.sh --agent-mode     # machine-readable
./test_runner.sh -v

# optional
dub test --compiler=ldc2          # unittests in src/
dub run :tests --compiler=ldc2    # tests/ runner (AST/parser/integration)
./tests/ctfe_parity/parity_runner.sh
./tests/output_parity/parity_runner.sh
```

`test_runner.sh` expects `wasm3` and `wasm2wat` on PATH.

Milestones live in `tests/milestones/<name>/{test.d,config.json,expected.txt}`. Config `type` is one of: `compile_only`, `wasm_exec`, `ctfe_eval`, `ctfe_output`, `compile_error`, `ffi_exec`.

Parity tests (`tests/ctfe_parity/`, `tests/output_parity/`) must pass on every listed backend. See `tests/PARITY.md`.

When adding a capability, add a milestone (or parity test) **first**, then implement.

---

## Pipeline — where to edit

```
.d source
  → parser/tree_sitter_bridge.d     # TSNode → AST
  → semantic/feature_validator.d    # unsupported-feature errors
  → semantic/mixin_expander.d       # mixins, static if, static assert
  → semantic/type_checker.d         # types, overloads, construction
  → semantic/ctfe.d + ctfe_runtime.d
  → codegen/emitter.d               # WASM module / function collection
  → codegen/wasm/                   # expression/statement/call emission
  → codegen/native/                 # ARM64 copy-and-patch (macOS-oriented)
```

| Task | Start here |
|------|------------|
| New syntax | `grammar/tree-sitter-d` node types, then `parser/tree_sitter_bridge.d`, then `ast/` |
| Type / construction / methods | `semantic/type_checker.d` |
| WASM opcodes / locals / calls | `codegen/wasm/emit_*.d`, `codegen/wasm/func_context.d` |
| Native ARM64 | `codegen/native/backend.d` |
| Diagnostics | `diagnostic/error_format.d` |
| Host/FFI | `runtime/ffi_trampoline.c`, `src/runtime/ffi_bindings.d`, `semantic/ctfe_runtime.d` |

AST nodes: `src/ast/nodes.d`, `expressions.d`, `statements.d`.

---

## Language subset (do not invent)

Supported in spirit: functions, structs, classes (manual memory, vtables), interfaces, arrays, CTFE, mixins, templates (growing), `extern(C)` FFI, `extern(Objective-C)` on macOS.

`ClassName(args)` constructs a **stack** class instance (and calls `this()` if present). `new ClassName(args)` is heap allocation and requires `@gc` on the enclosing function.

Do not silently accept unsupported D. Fail with a precise error (`feature_validator` / `TypeError` / `EmitError`) and a hint.

---

## Working rules

- **General implementations only.** No `if (funcName == "add")`, no literals copied from `test.d`, no golden-output hardcoding.
- Smallest change that makes the failing test pass *for any similar input*.
- Match surrounding D style. No narrating comments. Comments only for non-obvious constraints.
- Prefer fixing the compiler over weakening a test. If a test is actually wrong, say so.
- After codegen changes, run the relevant milestone and a nearby example (`examples/`, `./d2wasm -r …`).
- Native ARM64 and ObjC/Metal are macOS features. On Linux, keep the WASM path working; wrap Apple APIs in `version (OSX)`.
- wasm3 C API: memory belongs to the **module** (`m3_GetMemory(mod, …)`), not the runtime. D bindings live in `thirdparty/wasm3-d/source/wasm3/binding/binding.d`.

---

## Longer docs

| File | What |
|------|------|
| `DEVELOPMENT.md` | Ethos, milestone loop, test types |
| `ARCHITECTURE.md` | Pipeline and module map |
| `tests/PARITY.md` | CTFE / output parity |
| `INCREMENTAL.md` | Function-level cache |
| `notes/` | Decision records |
| `docs/design/` | Class/vtable notes |

README.md is stale; do not treat it as current scope.
