#!/bin/bash
set -euo pipefail

WASM3_SRC="$HOME/.dub/packages/wasm3-d-0.3.0/wasm3-d/wasm3-main/source"
WASM3_LIB="$HOME/.dub/packages/wasm3-d-0.3.0/wasm3-d/build/libm3.a"

FFI_CFLAGS=$(pkg-config --cflags libffi)
FFI_LIBS=$(pkg-config --libs libffi)

echo "=== Compiling host.c ==="
cc -O2 -I"$WASM3_SRC" $FFI_CFLAGS host.c "$WASM3_LIB" $FFI_LIBS -framework AppKit -o host

echo "=== Assembling test.wat ==="
wat2wasm test.wat -o test.wasm

echo "=== Running ==="
./host
