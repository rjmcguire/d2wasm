#!/bin/bash
# Build the X11 window demo (Linux / WSL with an X server or WSLg).
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
./d2wasm --target=native --link-dylib X11 demos/x11_window/window.d -o demos/x11_window/window
echo "Built demos/x11_window/window"
echo "Run:  ./demos/x11_window/window"
echo "Quit: click the window or press a key"
