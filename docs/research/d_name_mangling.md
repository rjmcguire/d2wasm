# D Name Mangling Specification

**Date:** 2026-02-07
**Source:** https://dlang.org/spec/abi.html

## Overview

D accomplishes typesafe linking by mangling identifiers to include scope and type information. This allows:
- Multiple functions with same name but different types (overloading)
- Symbols from different modules to coexist
- Type-safe linking across compilation units

## Basic Structure

```
MangledName:
    _D QualifiedName Type      // Normal symbol
    _D QualifiedName Z         // Internal symbol
```

The `_D` prefix identifies D symbols.

## Qualified Names

```
QualifiedName:
    SymbolFunctionName
    SymbolFunctionName QualifiedName

SymbolFunctionName:
    SymbolName
    SymbolName TypeFunctionNoReturn
    SymbolName M TypeModifiers? TypeFunctionNoReturn
```

The `M` indicates a method requiring a `this` pointer.

## LName (Length-prefixed Name)

```
LName:
    Number Name
```

Each identifier is prefixed by its length in decimal.

**Examples:**
- `foo` → `3foo`
- `bar` → `3bar`
- `animals` → `7animals`

## Module Path Encoding

Module paths are encoded as a sequence of LNames.

**Example:** `module animals.mammals.dog;`
```
7animals7mammals3dog
```

## Complete Symbol Mangling

**Example:** Function `speak` in module `animals.dog` returning `int`:
```d
module animals.dog;
int speak() { return 42; }
```

Mangled as:
```
_D7animals3dog5speakFZi
```

Breaking it down:
- `_D` — D symbol prefix
- `7animals` — module part 1 (length 7)
- `3dog` — module part 2 (length 3)
- `5speak` — function name (length 5)
- `F` — function with D calling convention
- `Z` — no parameters
- `i` — returns int

## Type Mangling

### Basic Types
| D Type | Mangled |
|--------|---------|
| `void` | `v` |
| `bool` | `b` |
| `byte` | `g` |
| `ubyte` | `h` |
| `short` | `s` |
| `ushort` | `t` |
| `int` | `i` |
| `uint` | `k` |
| `long` | `l` |
| `ulong` | `m` |
| `float` | `f` |
| `double` | `d` |
| `char` | `a` |
| `wchar` | `u` |
| `dchar` | `w` |

### Derived Types
| Type | Mangled |
|------|---------|
| Pointer to T | `P` Type |
| Dynamic array of T | `A` Type |
| Static array of T (n elements) | `G` Number Type |
| Associative array K→V | `H` Type Type |

### Type Modifiers
| Modifier | Mangled |
|----------|---------|
| `const` | `x` |
| `immutable` | `y` |
| `shared` | `O` |
| `inout` (wild) | `Ng` |

## Function Type Mangling

```
TypeFunction:
    CallConvention FuncAttrs? Parameters? ParamClose Type
```

### Calling Conventions
| Convention | Mangled |
|------------|---------|
| D | `F` |
| C | `U` |
| C++ | `R` |
| Windows | `W` |

### Parameter Close
| Meaning | Mangled |
|---------|---------|
| No variadic | `Z` |
| D variadic (...) | `Y` |
| C variadic (...) | `X` |

### Function Attributes
- Pure: `Na`
- Nothrow: `Nb`
- @nogc: `Ni`
- @safe: `Nf`
- @trusted: `Ne`
- ref return: `Nc`
- scope: `NI` or `Nl`

## Method Mangling

Methods include `M` to indicate they require `this`:

```d
struct Dog {
    int speak() { return 1; }
}
```

Mangled as:
```
_D3Dog5speakMFZi
```

The `M` before `FZi` indicates it's a method.

## Examples

### Simple function
```d
module foo;
int bar(int x) { return x; }
```
Mangled: `_D3foo3barFiZi`
- `_D` + `3foo` + `3bar` + `F` (D calling) + `i` (int param) + `Z` (end params) + `i` (returns int)

### Method in struct
```d
module zoo;
struct Animal {
    void speak() {}
}
```
Mangled: `_D3zoo6Animal5speakMFZv`

### Nested module
```d
module std.stdio;
void writeln() {}
```
Mangled: `_D3std5stdio7writelnFZv`

## Back References

To reduce symbol length, repeated type or identifier sequences can use back references:
- `Q` followed by a base-26 encoded offset to the original

This is an optimization we can defer.

## Our Implementation Plan

### Phase 1: Basic Mangling
- `_D` prefix
- Length-prefixed module path
- Length-prefixed symbol name
- Basic type suffixes

### Phase 2: Function Types
- Calling convention
- Parameter types
- Return type

### Phase 3: Methods
- `M` for methods
- Struct/class name in qualified path

### Phase 4: Optimizations
- Back references (optional, for symbol size)

## Demangling

For error messages, we need to demangle back to human-readable:
```
_D7animals3dog5speakFZi → animals.dog.speak() → int
```

Should store both mangled (for codegen) and demangled (for errors) forms.
