# Mixin DSL Demo

Demonstrates D's powerful string mixins to generate code at compile time.

A `generateProperty()` function creates getter/setter boilerplate,
which is then mixed into the code at compile time.

## Build

```bash
cd ~/projects/d-to-wasm-compiler
./d2wasm demos/mixin_dsl/properties.d -o demos/mixin_dsl/properties.wasm
```

## What This Demonstrates

1. **String concatenation** in CTFE (`~` operator)
2. **String mixins** (`mixin(...)`)
3. **Code generation** at compile time
4. **Zero-cost abstractions** - no runtime overhead

## The Magic

```d
mixin(generateProperty("x"));
```

Expands at compile time to:
```d
int _x;
int get_x() { return _x; }
void set_x(int v) { _x = v; }
```

## Status

- [x] String concatenation in CTFE
- [x] mixin() statement
- [ ] Global variable declarations from mixin
- [ ] Multiple mixins generating code
