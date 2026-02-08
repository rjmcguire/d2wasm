# Vtable Layout Design

**Date:** 2026-02-08
**Status:** Implemented (Milestone 159)

## Goals

1. Fast virtual dispatch (no overhead for type info lookup)
2. Rich error messages (know actual type when crash occurs)
3. Clean separation (dispatch code doesn't see debug info)

## Memory Layout

```
Data section for class Dog:

  TypeInfo (8 bytes):
    offset T+0:  nameOffset (u32) → points to "Dog" string in data section
    offset T+4:  nameLen (u32)    → 3

  Vtable preamble + table:
    offset V-4:  typeInfoPtr (u32) → T (points to TypeInfo)
    offset V+0:  method0_ptr (u32) ← vtable_ptr points HERE
    offset V+4:  method1_ptr (u32)
    offset V+8:  method2_ptr (u32)
    ...
```

**Key insight:** `vtable_ptr` points to V (first method pointer), not V-4. 
Dispatch code indexes directly: `vtable_ptr + methodIndex * 4`.
Error handler looks at `vtable_ptr - 4` to find type info.

## Object Layout

```
Instance of Dog:
    offset 0:  vtable_ptr (u32) → V (points to method[0])
    offset 4:  field0
    offset 8:  field1
    ...
```

## Virtual Dispatch (fast path)

```wasm
;; obj.speak() where speak is method index 1
local.get $obj
i32.load          ;; load vtable_ptr
i32.const 4       ;; method index * 4
i32.add
i32.load          ;; load function pointer
call_indirect     ;; dispatch
```

No type info access on the fast path.

## Error Handler (slow path)

When a trap occurs inside a virtual method:

```d
uint vtable_ptr = load(obj + 0);
uint typeInfoPtr = load(vtable_ptr - 4);
uint nameOffset = load(typeInfoPtr + 0);
uint nameLen = load(typeInfoPtr + 4);
string typeName = readMemory(nameOffset, nameLen);
// Now we can report: "error in Dog.speak()"
```

## Implementation Steps

### Milestone 157: Vtable Generation

1. **Collect virtual methods** during symbol collection
   - Mark methods as virtual (all methods virtual for now, optimize later)
   - Assign method indices (0, 1, 2, ...)

2. **Generate vtable in data section**
   - Emit class name string → nameOffset
   - Emit TypeInfo {nameOffset, nameLen} → typeInfoOffset
   - Emit typeInfoPtr (points to TypeInfo)
   - Emit method pointers (this is where vtable starts)
   - Store vtable offset in ClassDecl.vtableOffset

3. **Initialize vtable_ptr in emitClassVarDecl**
   - Instead of storing 0, store ClassDecl.vtableOffset

### Milestone 158: Virtual Method Dispatch

1. **Type check virtual calls**
   - `obj.method()` resolves method, checks signature

2. **Emit indirect call**
   - Load vtable_ptr from object
   - Add method index * 4
   - Load function pointer
   - call_indirect with correct type signature

### Milestone 159: Error Integration

1. **Extend error handler** to read type info
2. **Format errors** with actual type name

## TypeInfo Extension (future)

```
TypeInfo (extended):
    nameOffset, nameLen     ;; class name
    parentTypeInfo          ;; for inheritance chain
    classSize               ;; for allocation
    flags                   ;; abstract, final, etc.
```

## Method Index Assignment

For single inheritance, child class extends parent's vtable:

```
Animal vtable:     [speak:0] [eat:1]
Dog vtable:        [speak:0] [eat:1] [fetch:2]  ← Dog overrides speak, adds fetch
```

Override: same index, different function pointer.
New method: appended at end.
