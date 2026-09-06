#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
./d2wasm --target=native demos/x11_plasma/plasma.d -o demos/x11_plasma/plasma
echo "Built demos/x11_plasma/plasma"
echo "Run:  ./demos/x11_plasma/plasma   (or: ./d2wasm -r demos/x11_plasma/plasma.d)"
echo "Quit: click or press a key"
