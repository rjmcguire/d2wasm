#!/bin/sh
# Build the FFI trampoline C object file
# Called by dub preBuildCommands
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WASM3_INC=""
for d in \
    "$ROOT/thirdparty/wasm3-d/wasm3-main/source" \
    "$HOME/.dub/packages/wasm3-d/0.3.0/wasm3-d/wasm3-main/source" \
    "$HOME/.dub/packages/wasm3-d-0.3.0/wasm3-d/wasm3-main/source"
do
    if [ -f "$d/wasm3.h" ]; then
        WASM3_INC="$d"
        break
    fi
done

if [ -z "$WASM3_INC" ]; then
    echo "error: wasm3.h not found (expected thirdparty/wasm3-d/wasm3-main/source)" >&2
    exit 1
fi

FFI_CFLAGS=$(pkg-config --cflags libffi 2>/dev/null || true)

if [ ! -f runtime/ffi_trampoline.o ] || [ runtime/ffi_trampoline.c -nt runtime/ffi_trampoline.o ]; then
    cc -c -O2 -fPIC -I"$WASM3_INC" $FFI_CFLAGS runtime/ffi_trampoline.c -o runtime/ffi_trampoline.o
fi
