# D Module System

**Date:** 2026-02-07
**Source:** https://dlang.org/spec/module.html

## Overview

D modules have a one-to-one correspondence with source files (by default). A module:
- Acts as a namespace for its contents
- Can be grouped into hierarchies called packages
- Can be imported by other modules

## Module Declaration

```d
module path.to.modulename;
```

### Syntax

```
ModuleDeclaration:
    ModuleAttributes? module ModuleFullyQualifiedName ;

ModuleFullyQualifiedName:
    ModuleName
    Packages . ModuleName

Packages:
    PackageName
    Packages . PackageName
```

### Examples

```d
// File: animals/mammals/dog.d
module animals.mammals.dog;

// File: utils.d (no explicit declaration)
// Module name defaults to "utils"
```

### Key Points

1. If absent, module name defaults to filename (stripped of path and extension)
2. Must be first declaration in file (after comments)
3. Package names correspond to directory structure (by convention, not requirement)
4. Names should be lowercase for filesystem compatibility

## D's Flexibility

**Important for our compiler:** D does NOT require strict filesystem mapping.

```d
// File can be named anything.d but declare:
module completely.different.name;
```

This means:
- One file can contain symbols in any namespace
- Module name is what the code says, not the filename
- We should respect this flexibility

## Import Declarations

### Basic Import

```d
import std.stdio;
```

All public symbols from `std.stdio` become available.

### Static Import

```d
static import std.stdio;

// Must use fully qualified:
std.stdio.writeln("hello");  // OK
writeln("hello");            // Error
```

### Renamed Import

```d
import io = std.stdio;

io.writeln("hello");  // OK
```

### Selective Import

```d
import std.stdio : writeln, write;

writeln("hello");  // OK
readln();          // Error - not imported
```

### Renamed Selective Import

```d
import std.stdio : log = writeln;

log("hello");  // Calls writeln
```

### Public Import (Re-export)

```d
module mylib;
public import std.stdio;  // Users of mylib can access stdio symbols
```

## Visibility

| Visibility | Meaning |
|------------|---------|
| `public` | Accessible from other modules |
| `private` | Only this module |
| `package` | This package and subpackages |
| `protected` | For class inheritance |

Default is `public` at module scope.

## Symbol Lookup

Two-phase lookup when a symbol is used unqualified:

**Phase 1: Module Scope**
- Inner to outer scopes
- Local declarations → enclosing scopes → module scope

**Phase 2: Imports**
- Only if Phase 1 fails
- All imported symbols at that scope level

## Package Module

A special `package.d` file can represent a package:

```
mylib/
├── package.d      // module mylib (the package itself)
├── foo.d          // module mylib.foo
└── bar.d          // module mylib.bar
```

```d
// mylib/package.d
module mylib;
public import mylib.foo;
public import mylib.bar;
```

## Implementation Plan for Our Compiler

### Phase 1: Module Declaration
- Parse `module a.b.c;` statement
- Store module path as `string[]`
- Default to filename if no declaration
- Allow any module path (don't enforce filesystem)

### Phase 2: Module Context
- Track current module in `CompilerContext`
- All symbols tagged with their module
- Name mangling uses full module path

### Phase 3: Single-File Compilation
- One module per compilation unit
- No imports yet (all symbols in one file)
- Name mangling enables future linking

### Phase 4: Import Resolution (future)
- Parse `import` statements
- Resolve module name → source file
- Load and parse imported modules
- Build dependency graph
- Symbol visibility checking

### Phase 5: Separate Compilation (future)
- Compile modules independently
- Generate interface files (.di)
- Link at final stage

## Open Questions

1. **Module search paths:** How do we find `import foo.bar;`?
   - Search paths list?
   - Relative to current file?
   - Package root?

2. **Circular imports:** D allows them with some restrictions
   - Need to handle forward references
   - May require multiple passes

3. **Public imports:** When `B` publicly imports `C`, do `C`'s symbols appear in `B`'s mangled names?
   - Probably no — they stay in `C`'s namespace
   - Just re-exported

## Test Cases to Consider

```d
// Test 1: Explicit module declaration
module foo.bar.baz;
int x;  // Should mangle as _D3foo3bar3baz1xi

// Test 2: No declaration (default from filename)
// File: utils.d
int helper();  // Should mangle as _D5utils6helperFZi

// Test 3: Nested symbols
module mymod;
struct S {
    int method();  // _D5mymod1S6methodMFZi
}

// Test 4: Different module than filesystem
// File: src/impl/thing.d
module api.public_interface;  // Allowed!
```
