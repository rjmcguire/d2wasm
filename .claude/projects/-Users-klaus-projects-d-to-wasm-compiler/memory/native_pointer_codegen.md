---
name: Native pointer codegen fixes
description: ARM64 JIT pointer indexing bugs — element size, float stores, byte stores
type: project
---

Three pointer codegen bugs fixed in the native ARM64 backend:

1. **Pointer elemSize was 0**: `float*`, `ubyte*` etc. params/locals had no element size set, so `ptr[i]` computed `ptr + i` instead of `ptr + i * elemSize`. Fixed by computing `ptrElemSize` from `PointerType.pointeeType` during variable registration.

2. **Float pointer stores used wrong register**: Float expressions leave results in `d0` (FP register), but the scalar pointer store path read from `x0` (integer register). Fixed with FMOV x0,d0 + FCVT s0,d0 + STR s0 for f32 stores.

3. **Byte stores used 32-bit STR**: `emitStoreToPointerFromX9(0)` is STR w9 (4 bytes). For ubyte static array fields (`buf.data[j] = val`), this overwrites 3 adjacent bytes. Fixed to use STRB w1 when `elemSize == 1`.

**Why:** These all surfaced while getting the editor demo running in JIT mode.
**How to apply:** When adding new store paths through pointers or struct fields, always check element size and use the right-width store instruction. The slice field store path may have the same byte-store issue if ubyte slices are used.
