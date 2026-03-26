#!/bin/bash
# Milestone 260: Verify AOT ObjC symbol relocations
# Compiles to native binary (not JIT), links with ObjC frameworks, runs
DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$DIR/../../../d2wasm"
BIN="$DIR/test_bin"

# Clean up
rm -f "$BIN"

# Compile + link (compiler handles pragma(lib) → -framework flags)
if ! "$COMPILER" --target arm64-macos -o "$BIN" "$DIR/test.d" 2>&1; then
    echo "Compilation failed"
    exit 1
fi

# Run and check exit code
"$BIN"
EXIT=$?
if [ "$EXIT" -ne 42 ]; then
    echo "Expected exit code 42, got $EXIT"
    exit 1
fi
