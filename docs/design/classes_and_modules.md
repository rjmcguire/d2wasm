# Classes and Modules Design

**Date:** 2026-02-07
**Status:** Design Phase

## Overview

This document captures our design decisions for implementing classes and modules in the D-to-WASM compiler.

## Key Decisions

### 1. Module Support Before Classes

Classes require proper name mangling, which requires module awareness. Implementation order:

1. Module declaration parsing
2. Name mangling infrastructure  
3. Module-aware symbol table
4. Classes with vtables

### 2. D-Compatible Name Mangling

We will follow D's official mangling specification:

```
_D <module_path> <symbol_name> <type_signature>
```

Example: `module animals.dog; int speak()` → `_D7animals3dog5speakFZi`

This enables:
- Future interop with DMD/LDC-compiled code
- Consistent, well-defined scheme
- Overloading support (via type signature)

### 3. Classes as Structs with vtable

Memory layout:

```
Struct:                     Class:
┌─────────────┐             ┌─────────────┐
│ field0      │             │ vtable_ptr  │ ← implicit first field
│ field1      │             │ field0      │
│ ...         │             │ field1      │
└─────────────┘             └─────────────┘
```

Code reuse from struct implementation:
- Field layout calculation
- Field access codegen
- Constructor/destructor handling
- Method dispatch (extended for virtual)

### 4. No `new` Keyword Yet

Use `__new` method for allocation to keep semantics explicit:

```d
class Dog {
    int age;
    this(int a) { age = a; }
    
    // Compiler generates:
    static Dog __new(int a) {
        Dog ptr = cast(Dog) __ctfe_alloc(Dog.sizeof);
        ptr.__vtable = &Dog___vtable;
        ptr.__ctor(a);
        return ptr;
    }
}

// Usage:
Dog d = Dog.__new(5);
```

This avoids:
- Implying GC semantics
- Special syntax parsing
- Hidden magic

### 5. One Constructor Per Class (For Now)

No function overloading yet. Single `__new` and single `this()` per class.

Overloading requires:
- Symbol table changes (name → list of overloads)
- Overload resolution in type checker
- Extended name mangling (parameter types)

Deferred to later milestone.

### 6. Devirtualization Over Fancy Dispatch

Our benchmarks showed:
- vtable dispatch: ~0.95 ns, O(1), consistent
- Chain dispatch: 1.34x-11x slower depending on scenario

Optimization strategy:
- Use vtables for correctness
- Devirtualize at compile time when type is known
- CTFE has full type knowledge → aggressive devirtualization
- Inlining exposes further optimization opportunities

No inline caching or chain dispatch needed.

## Implementation Phases

### Phase 1: Module Declaration (Milestone 150)

**Goal:** Parse `module` declarations, track module context

**Changes:**
- `src/parser/tree_sitter_bridge.d`: Parse `module a.b.c;`
- `src/ast/nodes.d`: Add `ModuleDecl` node
- `src/semantic/`: Add `CompilerContext.currentModule`

**Test:**
```d
module foo.bar;
int x = 42;
// Verify: module path is ["foo", "bar"]
```

### Phase 2: Name Mangling (Milestone 151)

**Goal:** Implement D-compatible name mangling

**Changes:**
- `src/codegen/mangle.d`: New file with mangling functions
- Update emitter to use mangled names
- Store both mangled and demangled for errors

**Functions:**
```d
string mangle(string[] modulePath, string name, Type type);
string demangle(string mangled);  // For error messages
```

**Test:**
```d
module test;
int foo();
// Mangled: _D4test3fooFZi
```

### Phase 3: Module-Aware Symbols (Milestone 152)

**Goal:** Qualify symbols with their module

**Changes:**
- `src/semantic/symbol_table.d`: Track symbol's module
- Lookup uses (module, name) pair
- Cross-module references prepared (but not imports yet)

### Phase 4: Class Declaration (Milestone 153)

**Goal:** Parse class syntax, build vtable metadata

**Changes:**
- `src/parser/tree_sitter_bridge.d`: Parse `class Foo : Bar { }`
- `src/ast/nodes.d`: Add `ClassDecl` node
- `src/semantic/type_checker.d`: Validate class structure

**Parsed info:**
- Class name
- Base class (if any)
- Fields
- Methods (virtual by default)
- Constructor

### Phase 5: vtable Generation (Milestone 154)

**Goal:** Generate vtable for each class

**vtable layout:**
```
vtable[0] = typeinfo pointer (optional, for RTTI)
vtable[1] = method0 pointer
vtable[2] = method1 pointer
...
```

**Inheritance:**
- Derived class vtable starts with base class methods
- Overridden methods replace base pointers
- New methods appended

### Phase 6: Class Codegen (Milestone 155)

**Goal:** Emit code for class instantiation and method calls

**`__new` method:**
1. `__ctfe_alloc(sizeof(Class))`
2. Store vtable pointer at offset 0
3. Call constructor
4. Return pointer

**Virtual dispatch:**
1. Load vtable pointer from object (offset 0)
2. Load method pointer from vtable (offset = slot × ptrsize)
3. Call indirect

**Devirtualization:**
- If type checker knows concrete type → direct call
- Skip vtable lookup entirely

### Phase 7: Inheritance (Milestone 156)

**Goal:** Support single inheritance

**Layout:**
```
class Animal { int age; }
class Dog : Animal { int bones; }

Dog layout:
┌─────────────┐
│ vtable_ptr  │
│ age         │ ← from Animal
│ bones       │ ← from Dog
└─────────────┘
```

**Method resolution:**
- Walk inheritance chain
- Build combined vtable
- Override slots for overridden methods

## vtable Implementation Details

### For WASM

WASM has `call_indirect` with function tables:

```wasm
;; vtable is indices into the function table
;; Object stores vtable base index

;; Virtual call:
local.get $this
i32.load          ;; load vtable base index
i32.const <slot>
i32.add           ;; vtable_base + method_slot
call_indirect
```

### For Native (ARM64)

Classic function pointer table:

```asm
; Load vtable pointer
ldr x8, [x0]          ; x8 = vtable ptr

; Load method pointer  
ldr x9, [x8, #<slot * 8>]  ; x9 = method ptr

; Call
blr x9
```

## Error Messages

Preserve human-readable names for errors:

```
error: method 'speak' not found in class 'Dog'
 --> animals/dog.d:10:5
  |
10|     this.speak();
  |          ^^^^^ unknown method
```

Not:

```
error: symbol _D7animals3dog3Dog5speakMFZv not found
```

Store demangled names alongside mangled in symbol table.

## Testing Strategy

### Unit Tests

1. Module parsing: various `module` declarations
2. Name mangling: encode/decode round-trip
3. vtable layout: correct offsets
4. Method resolution: overrides work correctly

### Integration Tests

```d
// milestone_153_basic_class
module test;

class Animal {
    int speak() { return 0; }
}

class Dog : Animal {
    override int speak() { return 1; }
}

enum result = {
    Animal a = Dog.__new();
    return a.speak();  // Should return 1 (virtual dispatch)
}();

static assert(result == 1);
```

## Open Questions

1. **Interfaces:** Deferred. Need multiple vtable pointers.

2. **RTTI:** Minimal for now. Store TypeInfo pointer in vtable[0]?

3. **Destructor timing:** Without GC, when are class destructors called?
   - Explicit `destroy(obj)`?
   - Scope guard with `scope` storage class?
   - Defer to user code?

4. **Null checks:** Emit null check before vtable load?
   - Debug mode: yes
   - Release: optional flag

## Success Criteria

- [ ] Module declarations parsed and stored
- [ ] Name mangling follows D spec
- [ ] Class syntax parsed
- [ ] vtable generated correctly
- [ ] Virtual dispatch works in CTFE
- [ ] Single inheritance works
- [ ] Devirtualization works when type is known
- [ ] Error messages show human-readable names
