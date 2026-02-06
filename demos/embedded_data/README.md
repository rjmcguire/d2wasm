# Embedded Data Demo

Demonstrates D's `import()` expression to embed files at compile time.

Shader source code and binary data are baked directly into the WASM binary -
no need to load them at runtime!

## Build

```bash
cd ~/projects/d-to-wasm-compiler
./d2wasm demos/embedded_data/embed.d -o demos/embedded_data/embed.wasm
```

## What This Demonstrates

1. **import() expression** - reads files at compile time
2. **Embedded strings** - file contents as enum
3. **Zero-cost resources** - no file I/O at runtime
4. **Asset bundling** - shaders, configs, data all in one binary

## Use Cases

- Embed shaders for WebGL
- Embed configuration files
- Embed small binary assets
- Embed lookup tables or data files

## Status

- [x] import() expression
- [x] String enum from import()
- [ ] ubyte[] from import() for binary data
- [ ] Accessing imported data at runtime
