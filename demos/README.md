# D-to-WASM Compiler Demos

Demonstrations of the D-to-WASM compiler's capabilities.

## Demos

### 1. [Browser Game](browser_game/)
Simple score tracker showing D code running in the browser via WASM.
- Global variables
- Multiple exported functions
- JavaScript interop

### 2. [CTFE Lookup Table](ctfe_lookup_table/)
CRC32 table generated at compile time using CTFE.
- Static arrays
- Compile-time loops
- Zero runtime cost

### 3. [Mixin DSL](mixin_dsl/)
Generate getter/setter boilerplate using string mixins.
- String concatenation
- Code generation
- Metaprogramming

### 4. [Embedded Data](embedded_data/)
Embed files (shaders, data) directly into WASM using import().
- Compile-time file reading
- Asset bundling
- Zero-cost resources

## Building All Demos

```bash
cd ~/projects/d-to-wasm-compiler

# Build each demo
./d2wasm demos/browser_game/game.d -o demos/browser_game/game.wasm
./d2wasm demos/ctfe_lookup_table/crc32.d -o demos/ctfe_lookup_table/crc32.wasm
./d2wasm demos/mixin_dsl/properties.d -o demos/mixin_dsl/properties.wasm
./d2wasm demos/embedded_data/embed.d -o demos/embedded_data/embed.wasm
```

## Status

These demos represent **target** functionality. Some may not work yet!
Check each demo's README for current status.
