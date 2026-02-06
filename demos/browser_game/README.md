# Browser Game Demo

Simple score tracker demonstrating D compiled to WASM running in the browser.

## Build

```bash
cd ~/projects/d-to-wasm-compiler
./d2wasm demos/browser_game/game.d -o demos/browser_game/game.wasm
```

## Run

```bash
cd demos/browser_game
python3 -m http.server 8000
# Open http://localhost:8000
```

## Status

- [ ] Global variables (score)
- [ ] Multiple exported functions
- [ ] WASM exports
