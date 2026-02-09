# Parity Testing

This document explains the parity testing system for the D-to-WASM compiler.

## Overview

We have two types of backends:

1. **CTFE backends** — How compile-time function evaluation is executed
   - `wasm`: Compile to WASM, run with wasm3
   - `native`: Compile to native ARM64, execute directly

2. **Output backends** — What format the compiler produces
   - `wasm`: WebAssembly binary (.wasm)
   - *(future: native ARM64, x86_64, etc.)*

## Directory Structure

```
tests/
├── milestones/         # Development progress tests (single backend)
├── ctfe_parity/        # CTFE tests that must pass on ALL CTFE backends
│   └── parity_runner.sh
├── output_parity/      # Output tests that must pass on ALL output backends  
│   └── parity_runner.sh
└── PARITY.md           # This file
```

## When to Use Each

### `tests/milestones/`

Use for development progress. Tests here run with the default backend only.

- ✅ New features under development
- ✅ Backend-specific functionality
- ✅ Quick iteration during implementation

### `tests/ctfe_parity/`

Use when CTFE behavior must be identical across backends.

- ✅ Core CTFE operations (arithmetic, control flow)
- ✅ Host function calls (__writeln, etc.)
- ✅ Any CTFE feature that should work on both wasm and native

### `tests/output_parity/`

Use when compiled output must behave identically across backends.

- ✅ Runtime function behavior
- ✅ Memory layout
- ✅ Any runtime feature that should work on all output backends

## Running Parity Tests

```bash
# CTFE parity (tests both wasm and native CTFE backends)
./tests/ctfe_parity/parity_runner.sh

# Output parity (tests all output backends)
./tests/output_parity/parity_runner.sh

# Options
./tests/ctfe_parity/parity_runner.sh -v              # Verbose
./tests/ctfe_parity/parity_runner.sh --stop-on-fail  # Stop at first failure
```

## Adding a New Backend

1. **CTFE backend**: Edit `tests/ctfe_parity/parity_runner.sh`:
   ```bash
   CTFE_BACKENDS=(wasm native new_backend)
   ```

2. **Output backend**: Edit `tests/output_parity/parity_runner.sh`:
   ```bash
   OUTPUT_BACKENDS=(wasm new_backend)
   ```

All existing parity tests will automatically run against the new backend.

## Test Format

Same as milestone tests:

```
tests/ctfe_parity/parity_NNN_name/
├── test.d          # D source code
└── config.json     # Test configuration
```

### Config Types for CTFE Parity

- `compile_output`: Check stdout during compilation
- `wasm_exec`: Compile and run, check return value

### Config Types for Output Parity

- `wasm_exec`: Compile and run, check return value
- `compile_only`: Just verify compilation succeeds

## Known Issues

### Native CTFE Return Value Bug

The native CTFE backend currently returns 0 for all function calls instead of
the actual return value. This affects `wasm_exec` type tests but not
`compile_output` tests (side effects like __writeln still work).

**Tracked in**: MEMORY.md (search "Native CTFE")
**Workaround**: Use `compile_output` tests for CTFE parity until fixed

## Policy

1. **Milestones are not blocked by parity** — You can add a feature to one
   backend first, then achieve parity later.

2. **Parity tests are the source of truth** — If it's in a parity folder, it
   must pass on all backends before merging.

3. **Document parity gaps** — If a feature intentionally differs between
   backends, document it here.
