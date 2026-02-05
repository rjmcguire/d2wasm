/**
 * ARM64 Stencil Table
 * 
 * Contains machine code stencils for ARM64 native code generation.
 * 
 * Some stencils are extracted from compiled D code (see stencils/source.d).
 * Others are hand-crafted because they require specific register usage
 * that can't be expressed in D.
 * 
 * ARM64 Register Convention:
 *   x0      = arg0 / result
 *   x1      = arg1
 *   x2      = arg2
 *   x3      = arg3
 *   x8, x9  = scratch (caller-saved)
 *   x29     = frame pointer
 *   x30     = link register
 *   sp      = stack pointer
 */
module codegen.native.arm64.stencil_table;

import codegen.native.stencil_catalog;

// ============================================================================
// Extracted Stencils (from compiled D code)
// These operate on x0, x1 -> x0
// ============================================================================

// ----- Arithmetic -----

immutable stencil_add_i32 = Stencil(
    "add_i32",
    cast(immutable ubyte[])[0x20, 0x00, 0x00, 0x8b],  // ADD x0, x0, x1 (using 64-bit for simplicity)
    []
);

immutable stencil_sub_i32 = Stencil(
    "sub_i32",
    cast(immutable ubyte[])[0x00, 0x00, 0x01, 0xcb],  // SUB x0, x0, x1
    []
);

immutable stencil_mul_i32 = Stencil(
    "mul_i32",
    cast(immutable ubyte[])[0x20, 0x7c, 0x00, 0x9b],  // MUL x0, x1, x0
    []
);

immutable stencil_div_i32 = Stencil(
    "div_i32",
    cast(immutable ubyte[])[0x00, 0x0c, 0xc1, 0x9a],  // SDIV x0, x0, x1
    []
);

immutable stencil_mod_i32 = Stencil(
    "mod_i32",
    cast(immutable ubyte[])[
        0x08, 0x0c, 0xc1, 0x9a,  // SDIV x8, x0, x1
        0x00, 0x81, 0x01, 0x9b   // MSUB x0, x8, x1, x0
    ],
    []
);

immutable stencil_neg_i32 = Stencil(
    "neg_i32",
    cast(immutable ubyte[])[0x00, 0x00, 0x00, 0xcb],  // NEG x0, x0 (SUB x0, xzr, x0)
    []
);

// ----- Bitwise -----

immutable stencil_and_i32 = Stencil(
    "and_i32",
    cast(immutable ubyte[])[0x20, 0x00, 0x00, 0x8a],  // AND x0, x0, x1 (using 64-bit AND preserves behavior)
    []
);

immutable stencil_or_i32 = Stencil(
    "or_i32",
    cast(immutable ubyte[])[0x20, 0x00, 0x00, 0xaa],  // ORR x0, x0, x1 (64-bit)
    []
);

immutable stencil_xor_i32 = Stencil(
    "xor_i32",
    cast(immutable ubyte[])[0x20, 0x00, 0x00, 0xca],  // EOR x0, x0, x1 (64-bit)
    []
);

immutable stencil_shl_i32 = Stencil(
    "shl_i32",
    cast(immutable ubyte[])[
        0x28, 0x7c, 0x40, 0x93,  // SXTW x8, w1 (sign-extend shift amount)
        0x00, 0x20, 0xc8, 0x9a   // LSL x0, x0, x8
    ],
    []
);

immutable stencil_shr_i32 = Stencil(
    "shr_i32",
    cast(immutable ubyte[])[
        0x28, 0x7c, 0x40, 0x93,  // SXTW x8, w1
        0x00, 0x28, 0xc8, 0x9a   // ASR x0, x0, x8 (arithmetic shift)
    ],
    []
);

immutable stencil_not_i32 = Stencil(
    "not_i32",
    cast(immutable ubyte[])[0x00, 0x00, 0x20, 0xaa],  // MVN x0, x0 (ORN x0, xzr, x0)
    []
);

// ----- Comparison -----

immutable stencil_eq_i32 = Stencil(
    "eq_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0xeb,  // CMP x0, x1
        0xe0, 0x17, 0x9f, 0x1a   // CSET x0, eq
    ],
    []
);

immutable stencil_ne_i32 = Stencil(
    "ne_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0xeb,  // CMP x0, x1
        0xe0, 0x07, 0x9f, 0x1a   // CSET x0, ne
    ],
    []
);

immutable stencil_lt_i32 = Stencil(
    "lt_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0xeb,  // CMP x0, x1
        0xe0, 0xa7, 0x9f, 0x1a   // CSET x0, lt
    ],
    []
);

immutable stencil_le_i32 = Stencil(
    "le_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0xeb,  // CMP x0, x1
        0xe0, 0xc7, 0x9f, 0x1a   // CSET x0, le
    ],
    []
);

immutable stencil_gt_i32 = Stencil(
    "gt_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0xeb,  // CMP x0, x1
        0xe0, 0xd7, 0x9f, 0x1a   // CSET x0, gt
    ],
    []
);

immutable stencil_ge_i32 = Stencil(
    "ge_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0xeb,  // CMP x0, x1
        0xe0, 0xb7, 0x9f, 0x1a   // CSET x0, ge
    ],
    []
);

// ============================================================================
// Hand-Crafted Stencils
// These require specific register targeting or special instructions
// ============================================================================

// ----- Immediate Loading -----

/// Load 32-bit immediate into x0
/// MOV x0, #imm16_lo; MOVK x0, #imm16_hi, LSL 16
immutable stencil_load_imm32 = Stencil(
    "load_imm32",
    cast(immutable ubyte[])[
        0x00, 0x00, 0x80, 0xd2,  // MOV x0, #0 (hole: bits 5-20)
        0x00, 0x00, 0xa0, 0xf2   // MOVK x0, #0, LSL 16 (hole: bits 5-20)
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

/// Load 64-bit immediate into x0
/// MOV x0, #imm16_0; MOVK x0, #imm16_1, LSL 16; MOVK x0, #imm16_2, LSL 32; MOVK x0, #imm16_3, LSL 48
immutable stencil_load_imm64 = Stencil(
    "load_imm64",
    cast(immutable ubyte[])[
        0x00, 0x00, 0x80, 0xd2,  // MOV x0, #0
        0x00, 0x00, 0xa0, 0xf2,  // MOVK x0, #0, LSL 16
        0x00, 0x00, 0xc0, 0xf2,  // MOVK x0, #0, LSL 32
        0x00, 0x00, 0xe0, 0xf2   // MOVK x0, #0, LSL 48
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1),
        StencilHole(8, HoleKind.imm16_2, 2),
        StencilHole(12, HoleKind.imm16_3, 3)
    ]
);

/// Load 64-bit immediate into x9 (scratch, preserves args)
immutable stencil_load_imm64_to_scratch = Stencil(
    "load_imm64_to_scratch",
    cast(immutable ubyte[])[
        0x09, 0x00, 0x80, 0xd2,  // MOV x9, #0
        0x09, 0x00, 0xa0, 0xf2,  // MOVK x9, #0, LSL 16
        0x09, 0x00, 0xc0, 0xf2,  // MOVK x9, #0, LSL 32
        0x09, 0x00, 0xe0, 0xf2   // MOVK x9, #0, LSL 48
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1),
        StencilHole(8, HoleKind.imm16_2, 2),
        StencilHole(12, HoleKind.imm16_3, 3)
    ]
);

// ----- Memory Access (with offset holes) -----

/// Load 32-bit from [x0 + offset]
immutable stencil_load_i32 = Stencil(
    "load_i32",
    cast(immutable ubyte[])[
        0x08, 0x00, 0x80, 0x52,  // MOV w8, #offset_lo (hole)
        0x08, 0x00, 0xa0, 0x72,  // MOVK w8, #offset_hi, LSL 16 (hole)
        0x00, 0x68, 0xa8, 0xb8   // LDR w0, [x0, x8]
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

/// Store 32-bit w1 to [x0 + offset]
immutable stencil_store_i32 = Stencil(
    "store_i32",
    cast(immutable ubyte[])[
        0x08, 0x00, 0x80, 0x52,  // MOV w8, #offset_lo (hole)
        0x08, 0x00, 0xa0, 0x72,  // MOVK w8, #offset_hi, LSL 16 (hole)
        0x01, 0x68, 0x28, 0xb8   // STR w1, [x0, x8]
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

/// Load 64-bit from [x0 + offset]
immutable stencil_load_i64 = Stencil(
    "load_i64",
    cast(immutable ubyte[])[
        0x08, 0x00, 0x80, 0x52,  // MOV w8, #offset_lo (hole)
        0x08, 0x00, 0xa0, 0x72,  // MOVK w8, #offset_hi, LSL 16 (hole)
        0x00, 0x68, 0x68, 0xf8   // LDR x0, [x0, x8]
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

/// Store 64-bit x1 to [x0 + offset]
immutable stencil_store_i64 = Stencil(
    "store_i64",
    cast(immutable ubyte[])[
        0x08, 0x00, 0x80, 0x52,  // MOV w8, #offset_lo (hole)
        0x08, 0x00, 0xa0, 0x72,  // MOVK w8, #offset_hi, LSL 16 (hole)
        0x01, 0x68, 0x28, 0xf8   // STR x1, [x0, x8]
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

// ----- Local Variable Access (frame-relative) -----

/// Load 32-bit from [fp + offset]
immutable stencil_load_local_i32 = Stencil(
    "load_local_i32",
    cast(immutable ubyte[])[
        0x08, 0x00, 0x80, 0x52,  // MOV w8, #offset_lo (hole)
        0x08, 0x00, 0xa0, 0x72,  // MOVK w8, #offset_hi, LSL 16 (hole)
        0xa0, 0x6b, 0x68, 0xb8   // LDR w0, [fp, x8] (fp = x29)
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

/// Store 32-bit w0 to [fp + offset]
immutable stencil_store_local_i32 = Stencil(
    "store_local_i32",
    cast(immutable ubyte[])[
        0x08, 0x00, 0x80, 0x52,  // MOV w8, #offset_lo (hole)
        0x08, 0x00, 0xa0, 0x72,  // MOVK w8, #offset_hi, LSL 16 (hole)
        0xa0, 0x6b, 0x28, 0xb8   // STR w0, [fp, x8]
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

/// Load 64-bit from [fp + offset]
immutable stencil_load_local_i64 = Stencil(
    "load_local_i64",
    cast(immutable ubyte[])[
        0x08, 0x00, 0x80, 0x52,  // MOV w8, #offset_lo (hole)
        0x08, 0x00, 0xa0, 0x72,  // MOVK w8, #offset_hi, LSL 16 (hole)
        0xa0, 0x6b, 0x68, 0xf8   // LDR x0, [fp, x8]
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

/// Store 64-bit x0 to [fp + offset]
immutable stencil_store_local_i64 = Stencil(
    "store_local_i64",
    cast(immutable ubyte[])[
        0x08, 0x00, 0x80, 0x52,  // MOV w8, #offset_lo (hole)
        0x08, 0x00, 0xa0, 0x72,  // MOVK w8, #offset_hi, LSL 16 (hole)
        0xa0, 0x6b, 0x28, 0xf8   // STR x0, [fp, x8]
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

// ----- Compound Stencils -----
// These combine multiple operations to reduce overhead

/// Increment 32-bit local: [sp + offset]++
/// Replaces: load, move, imm 1, move, move, move, add, store (8 ops)
immutable stencil_inc_local_i32 = Stencil(
    "inc_local_i32",
    cast(immutable ubyte[])[
        0x08, 0x00, 0x80, 0x52,  // MOV w8, #offset_lo (hole)
        0x08, 0x00, 0xa0, 0x72,  // MOVK w8, #offset_hi, LSL 16 (hole)
        0xe0, 0x6b, 0x68, 0xb8,  // LDR w0, [sp, x8]
        0x00, 0x04, 0x00, 0x11,  // ADD w0, w0, #1
        0xe0, 0x6b, 0x28, 0xb8   // STR w0, [sp, x8]
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

// ----- Indirect Calls -----

/// Load pointer from [x9] into x9
immutable stencil_load_ptr_indirect = Stencil(
    "load_ptr_indirect",
    cast(immutable ubyte[])[0x29, 0x01, 0x40, 0xf9],  // LDR x9, [x9]
    []
);

/// Call function at address in x9
immutable stencil_call_indirect = Stencil(
    "call_indirect",
    cast(immutable ubyte[])[0x20, 0x01, 0x3f, 0xd6],  // BLR x9
    []
);

// ----- Stack Frame -----

/// Function prologue (no locals)
immutable stencil_prologue = Stencil(
    "prologue",
    cast(immutable ubyte[])[
        0xfd, 0x7b, 0xbf, 0xa9,  // STP x29, x30, [sp, #-16]!
        0xfd, 0x03, 0x00, 0x91   // MOV x29, sp
    ],
    []
);

/// Function prologue with locals (hole: stack size, must be 16-byte aligned)
immutable stencil_prologue_with_locals = Stencil(
    "prologue_with_locals",
    cast(immutable ubyte[])[
        0xfd, 0x7b, 0xbf, 0xa9,  // STP x29, x30, [sp, #-16]!
        0xfd, 0x03, 0x00, 0x91,  // MOV x29, sp
        0xff, 0x03, 0x00, 0xd1   // SUB sp, sp, #0 (hole: immediate)
    ],
    [
        StencilHole(8, HoleKind.frame_offset, 0)
    ]
);

/// Function epilogue (no locals)
immutable stencil_epilogue = Stencil(
    "epilogue",
    cast(immutable ubyte[])[
        0xfd, 0x7b, 0xc1, 0xa8,  // LDP x29, x30, [sp], #16
        0xc0, 0x03, 0x5f, 0xd6   // RET
    ],
    []
);

/// Function epilogue with locals (hole: stack size)
immutable stencil_epilogue_with_locals = Stencil(
    "epilogue_with_locals",
    cast(immutable ubyte[])[
        0xff, 0x03, 0x00, 0x91,  // ADD sp, sp, #0 (hole: immediate)
        0xfd, 0x7b, 0xc1, 0xa8,  // LDP x29, x30, [sp], #16
        0xc0, 0x03, 0x5f, 0xd6   // RET
    ],
    [
        StencilHole(0, HoleKind.frame_offset, 0)
    ]
);

// ----- Register Moves -----

/// MOV x1, x0
immutable stencil_move_result_to_arg1 = Stencil(
    "move_result_to_arg1",
    cast(immutable ubyte[])[0xe1, 0x03, 0x00, 0xaa],  // ORR x1, xzr, x0
    []
);

/// MOV x2, x0
immutable stencil_move_result_to_arg2 = Stencil(
    "move_result_to_arg2",
    cast(immutable ubyte[])[0xe2, 0x03, 0x00, 0xaa],  // ORR x2, xzr, x0
    []
);

/// MOV x3, x0
immutable stencil_move_result_to_arg3 = Stencil(
    "move_result_to_arg3",
    cast(immutable ubyte[])[0xe3, 0x03, 0x00, 0xaa],  // ORR x3, xzr, x0
    []
);

/// MOV x9, x0 (to scratch)
immutable stencil_move_result_to_scratch = Stencil(
    "move_result_to_scratch",
    cast(immutable ubyte[])[0xe9, 0x03, 0x00, 0xaa],  // ORR x9, xzr, x0
    []
);

/// MOV x0, x9 (from scratch)
immutable stencil_move_scratch_to_result = Stencil(
    "move_scratch_to_result",
    cast(immutable ubyte[])[0xe0, 0x03, 0x09, 0xaa],  // ORR x0, xzr, x9
    []
);

/// MOV x0, x1
immutable stencil_move_arg1_to_result = Stencil(
    "move_arg1_to_result",
    cast(immutable ubyte[])[0xe0, 0x03, 0x01, 0xaa],  // ORR x0, xzr, x1
    []
);

/// MOV x1, x2
immutable stencil_move_arg2_to_arg1 = Stencil(
    "move_arg2_to_arg1",
    cast(immutable ubyte[])[0xe1, 0x03, 0x02, 0xaa],  // ORR x1, xzr, x2
    []
);

/// MOV x8, x0 (scratch2 = result)
immutable stencil_move_result_to_scratch2 = Stencil(
    "move_result_to_scratch2",
    cast(immutable ubyte[])[0xe8, 0x03, 0x00, 0xaa],  // ORR x8, xzr, x0
    []
);

/// MOV x0, x8 (result = scratch2)
immutable stencil_move_scratch2_to_result = Stencil(
    "move_scratch2_to_result",
    cast(immutable ubyte[])[0xe0, 0x03, 0x08, 0xaa],  // ORR x0, xzr, x8
    []
);

// ----- Parameter Spilling (store arg registers to locals) -----

/// Store w1 (arg1) to [fp + offset]
immutable stencil_store_arg1_to_local_i32 = Stencil(
    "store_arg1_to_local_i32",
    cast(immutable ubyte[])[
        0x08, 0x00, 0x80, 0x52,  // MOV w8, #offset_lo (hole)
        0x08, 0x00, 0xa0, 0x72,  // MOVK w8, #offset_hi, LSL 16 (hole)
        0xa1, 0x6b, 0x28, 0xb8   // STR w1, [fp, x8]
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

/// Store w2 (arg2) to [fp + offset]
immutable stencil_store_arg2_to_local_i32 = Stencil(
    "store_arg2_to_local_i32",
    cast(immutable ubyte[])[
        0x08, 0x00, 0x80, 0x52,  // MOV w8, #offset_lo (hole)
        0x08, 0x00, 0xa0, 0x72,  // MOVK w8, #offset_hi, LSL 16 (hole)
        0xa2, 0x6b, 0x28, 0xb8   // STR w2, [fp, x8]
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

/// Store w3 (arg3) to [fp + offset]
immutable stencil_store_arg3_to_local_i32 = Stencil(
    "store_arg3_to_local_i32",
    cast(immutable ubyte[])[
        0x08, 0x00, 0x80, 0x52,  // MOV w8, #offset_lo (hole)
        0x08, 0x00, 0xa0, 0x72,  // MOVK w8, #offset_hi, LSL 16 (hole)
        0xa3, 0x6b, 0x28, 0xb8   // STR w3, [fp, x8]
    ],
    [
        StencilHole(0, HoleKind.imm16_0, 0),
        StencilHole(4, HoleKind.imm16_1, 1)
    ]
);

// ----- Stack Pointer -----

/// Get frame pointer into x0
immutable stencil_get_frame_pointer = Stencil(
    "get_frame_pointer",
    cast(immutable ubyte[])[0xe0, 0x03, 0x1d, 0xaa],  // ORR x0, xzr, x29 (MOV x0, fp)
    []
);

// ----- Return -----

immutable stencil_return_void = Stencil(
    "return_void",
    cast(immutable ubyte[])[0xc0, 0x03, 0x5f, 0xd6],  // RET
    []
);

immutable stencil_return_val = Stencil(
    "return_val",
    cast(immutable ubyte[])[0xc0, 0x03, 0x5f, 0xd6],  // RET (value already in x0)
    []
);

// ============================================================================
// Stencil Lookup Table
// ============================================================================

immutable Stencil*[string] stencilTable;

shared static this() {
    // Arithmetic
    stencilTable["add_i32"] = &stencil_add_i32;
    stencilTable["sub_i32"] = &stencil_sub_i32;
    stencilTable["mul_i32"] = &stencil_mul_i32;
    stencilTable["div_i32"] = &stencil_div_i32;
    stencilTable["mod_i32"] = &stencil_mod_i32;
    stencilTable["neg_i32"] = &stencil_neg_i32;
    
    // Bitwise
    stencilTable["and_i32"] = &stencil_and_i32;
    stencilTable["or_i32"] = &stencil_or_i32;
    stencilTable["xor_i32"] = &stencil_xor_i32;
    stencilTable["shl_i32"] = &stencil_shl_i32;
    stencilTable["shr_i32"] = &stencil_shr_i32;
    stencilTable["not_i32"] = &stencil_not_i32;
    
    // Comparison
    stencilTable["eq_i32"] = &stencil_eq_i32;
    stencilTable["ne_i32"] = &stencil_ne_i32;
    stencilTable["lt_i32"] = &stencil_lt_i32;
    stencilTable["le_i32"] = &stencil_le_i32;
    stencilTable["gt_i32"] = &stencil_gt_i32;
    stencilTable["ge_i32"] = &stencil_ge_i32;
    
    // Immediates
    stencilTable["load_imm32"] = &stencil_load_imm32;
    stencilTable["load_imm64"] = &stencil_load_imm64;
    stencilTable["load_imm64_to_scratch"] = &stencil_load_imm64_to_scratch;
    
    // Memory
    stencilTable["load_i32"] = &stencil_load_i32;
    stencilTable["store_i32"] = &stencil_store_i32;
    stencilTable["load_i64"] = &stencil_load_i64;
    stencilTable["store_i64"] = &stencil_store_i64;
    
    // Local variables
    stencilTable["load_local_i32"] = &stencil_load_local_i32;
    stencilTable["store_local_i32"] = &stencil_store_local_i32;
    stencilTable["load_local_i64"] = &stencil_load_local_i64;
    stencilTable["store_local_i64"] = &stencil_store_local_i64;
    
    // Compound operations
    stencilTable["inc_local_i32"] = &stencil_inc_local_i32;
    
    // Indirect calls
    stencilTable["load_ptr_indirect"] = &stencil_load_ptr_indirect;
    stencilTable["call_indirect"] = &stencil_call_indirect;
    
    // Stack frame
    stencilTable["prologue"] = &stencil_prologue;
    stencilTable["prologue_with_locals"] = &stencil_prologue_with_locals;
    stencilTable["epilogue"] = &stencil_epilogue;
    stencilTable["epilogue_with_locals"] = &stencil_epilogue_with_locals;
    
    // Register moves
    stencilTable["move_result_to_arg1"] = &stencil_move_result_to_arg1;
    stencilTable["move_result_to_arg2"] = &stencil_move_result_to_arg2;
    stencilTable["move_result_to_arg3"] = &stencil_move_result_to_arg3;
    stencilTable["move_result_to_scratch"] = &stencil_move_result_to_scratch;
    stencilTable["move_scratch_to_result"] = &stencil_move_scratch_to_result;
    stencilTable["move_arg1_to_result"] = &stencil_move_arg1_to_result;
    stencilTable["move_arg2_to_arg1"] = &stencil_move_arg2_to_arg1;
    stencilTable["move_result_to_scratch2"] = &stencil_move_result_to_scratch2;
    stencilTable["move_scratch2_to_result"] = &stencil_move_scratch2_to_result;
    
    // Parameter spilling
    stencilTable["store_arg1_to_local_i32"] = &stencil_store_arg1_to_local_i32;
    stencilTable["store_arg2_to_local_i32"] = &stencil_store_arg2_to_local_i32;
    stencilTable["store_arg3_to_local_i32"] = &stencil_store_arg3_to_local_i32;
    
    // Stack pointer
    stencilTable["get_frame_pointer"] = &stencil_get_frame_pointer;
    
    // Return
    stencilTable["return_void"] = &stencil_return_void;
    stencilTable["return_val"] = &stencil_return_val;
}

/// Get a stencil by name
const(Stencil)* getStencil(string name) {
    if (auto p = name in stencilTable) return *p;
    return null;
}

/// ARM64 stencil provider implementation
class ARM64StencilProvider : NativeStencilProvider {
    override const(Stencil)* getStencil(string name) {
        return .getStencil(name);
    }
    
    override bool validateCatalog() {
        return validateStencilProvider(this);
    }
    
    override string architecture() {
        return "arm64";
    }
}
