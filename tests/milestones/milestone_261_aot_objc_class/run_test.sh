#!/bin/bash
# Milestone 261: D-defined ObjC class in AOT binary
DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER="$DIR/../../../d2wasm"
BIN="$DIR/test_bin"

rm -f "$BIN"
if ! "$COMPILER" --target arm64-macos -o "$BIN" "$DIR/test.d" 2>&1; then
    echo "Compilation failed"
    exit 1
fi

"$BIN"
EXIT=$?
if [ "$EXIT" -ne 42 ]; then
    echo "Expected exit code 42, got $EXIT"
    exit 1
fi
