#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "=== Compiling D and running ==="
../../d2wasm metal_demo.d -r
