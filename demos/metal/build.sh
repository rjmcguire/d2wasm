#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "=== Compiling Metal bridge ==="
clang -shared -o libmetal_bridge.dylib metal_bridge.m \
    -framework Metal -framework Foundation -framework Cocoa -framework QuartzCore

echo "=== Compiling D and running ==="
../../d2wasm metal_demo.d -r \
    --link-framework Metal \
    --link-framework Foundation \
    --link-dylib ./libmetal_bridge.dylib
