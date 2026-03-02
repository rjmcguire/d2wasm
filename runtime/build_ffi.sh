#!/bin/sh
# Build the FFI trampoline C object file
# Called by dub preBuildCommands

WASM3_INC="$HOME/.dub/packages/wasm3-d-0.3.0/wasm3-d/wasm3-main/source"
FFI_CFLAGS=$(pkg-config --cflags libffi 2>/dev/null)

# Only rebuild if source is newer than object
if [ runtime/ffi_trampoline.c -nt runtime/ffi_trampoline.o ]; then
    cc -c -O2 -I"$WASM3_INC" $FFI_CFLAGS runtime/ffi_trampoline.c -o runtime/ffi_trampoline.o
fi
