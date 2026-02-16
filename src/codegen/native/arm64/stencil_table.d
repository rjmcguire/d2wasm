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

// All i32 arithmetic uses 32-bit (w) registers for correct wrapping of negative values.
// Zero-extended 32-bit values in 64-bit registers would break signed arithmetic
// (e.g., -1 + 1 would yield 0x100000000 instead of 0).

immutable stencil_add_i32 = Stencil(
    "add_i32",
    cast(immutable ubyte[])[0x20, 0x00, 0x00, 0x0b],  // ADD w0, w1, w0 (32-bit, wraps correctly)
    []
);

immutable stencil_add_i64 = Stencil(
    "add_i64",
    cast(immutable ubyte[])[0x20, 0x00, 0x00, 0x8b],  // ADD x0, x1, x0 (64-bit, for pointer arithmetic)
    []
);

immutable stencil_sub_i32 = Stencil(
    "sub_i32",
    cast(immutable ubyte[])[0x00, 0x00, 0x01, 0x4b],  // SUB w0, w0, w1 (32-bit)
    []
);

immutable stencil_mul_i32 = Stencil(
    "mul_i32",
    cast(immutable ubyte[])[0x20, 0x7c, 0x00, 0x1b],  // MUL w0, w1, w0 (32-bit)
    []
);

immutable stencil_div_i32 = Stencil(
    "div_i32",
    cast(immutable ubyte[])[0x00, 0x0c, 0xc1, 0x1a],  // SDIV w0, w0, w1 (32-bit)
    []
);

immutable stencil_mod_i32 = Stencil(
    "mod_i32",
    cast(immutable ubyte[])[
        0x08, 0x0c, 0xc1, 0x1a,  // SDIV w8, w0, w1 (32-bit)
        0x00, 0x81, 0x01, 0x1b   // MSUB w0, w8, w1, w0 (32-bit)
    ],
    []
);

immutable stencil_neg_i32 = Stencil(
    "neg_i32",
    cast(immutable ubyte[])[0x00, 0x00, 0x00, 0x4b],  // NEG w0, w0 (SUB w0, wzr, w0) (32-bit)
    []
);

// ----- Bitwise -----
// All i32 bitwise ops use 32-bit (w) registers to match int type semantics.

immutable stencil_and_i32 = Stencil(
    "and_i32",
    cast(immutable ubyte[])[0x20, 0x00, 0x00, 0x0a],  // AND w0, w1, w0 (32-bit)
    []
);

immutable stencil_or_i32 = Stencil(
    "or_i32",
    cast(immutable ubyte[])[0x20, 0x00, 0x00, 0x2a],  // ORR w0, w1, w0 (32-bit)
    []
);

immutable stencil_logical_and_i32 = Stencil(
    "logical_and_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x00, 0x71,  // CMP w0, #0
        0xe0, 0x07, 0x9f, 0x1a,  // CSET w0, NE
        0x3f, 0x00, 0x00, 0x71,  // CMP w1, #0
        0xe1, 0x07, 0x9f, 0x1a,  // CSET w1, NE
        0x00, 0x00, 0x01, 0x0a,  // AND w0, w0, w1
    ],
    []
);

immutable stencil_logical_or_i32 = Stencil(
    "logical_or_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x00, 0x71,  // CMP w0, #0
        0xe0, 0x07, 0x9f, 0x1a,  // CSET w0, NE
        0x3f, 0x00, 0x00, 0x71,  // CMP w1, #0
        0xe1, 0x07, 0x9f, 0x1a,  // CSET w1, NE
        0x00, 0x00, 0x01, 0x2a,  // ORR w0, w0, w1
    ],
    []
);

immutable stencil_xor_i32 = Stencil(
    "xor_i32",
    cast(immutable ubyte[])[0x20, 0x00, 0x00, 0x4a],  // EOR w0, w1, w0 (32-bit)
    []
);

immutable stencil_shl_i32 = Stencil(
    "shl_i32",
    cast(immutable ubyte[])[0x00, 0x20, 0xc1, 0x1a],  // LSL w0, w0, w1 (32-bit)
    []
);

immutable stencil_shr_i32 = Stencil(
    "shr_i32",
    cast(immutable ubyte[])[0x00, 0x28, 0xc1, 0x1a],  // ASR w0, w0, w1 (32-bit arithmetic shift)
    []
);

immutable stencil_not_i32 = Stencil(
    "not_i32",
    cast(immutable ubyte[])[0xe0, 0x03, 0x20, 0x2a],  // MVN w0, w0 (ORN w0, wzr, w0) (32-bit)
    []
);

immutable stencil_lsr_i32 = Stencil(
    "lsr_i32",
    cast(immutable ubyte[])[0x00, 0x24, 0xc1, 0x1a],  // LSR w0, w0, w1 (32-bit logical shift right)
    []
);

// ----- Comparison -----
// All comparisons use 32-bit CMP (w0, w1) for correct signed integer handling.
// Zero-extended 32-bit values in 64-bit registers would break signed comparisons.

immutable stencil_eq_i32 = Stencil(
    "eq_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0x6b,  // CMP w0, w1 (32-bit)
        0xe0, 0x17, 0x9f, 0x1a   // CSET w0, eq
    ],
    []
);

immutable stencil_ne_i32 = Stencil(
    "ne_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0x6b,  // CMP w0, w1 (32-bit)
        0xe0, 0x07, 0x9f, 0x1a   // CSET w0, ne
    ],
    []
);

immutable stencil_lt_i32 = Stencil(
    "lt_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0x6b,  // CMP w0, w1 (32-bit for signed comparison)
        0xe0, 0xa7, 0x9f, 0x1a   // CSET w0, lt
    ],
    []
);

immutable stencil_le_i32 = Stencil(
    "le_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0x6b,  // CMP w0, w1 (32-bit for signed comparison)
        0xe0, 0xc7, 0x9f, 0x1a   // CSET w0, le
    ],
    []
);

// Unsigned comparisons for bounds checking
// CSET uses inverted condition: CSET Rd, cond = CSINC Rd, xzr, xzr, invert(cond)
// lt_i32 uses 0xa7 (cond=1010=GE, inverts to LT signed)
// For "lo" (unsigned <), we invert to "hs" (0010), so byte becomes 0x27
// For "hs" (unsigned >=), we invert to "lo" (0011), so byte becomes 0x37
immutable stencil_lt_u32 = Stencil(
    "lt_u32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0x6b,  // CMP w0, w1 (32-bit)
        0xe0, 0x27, 0x9f, 0x1a   // CSET w0, lo (encode inverted HS=0010)
    ],
    []
);

immutable stencil_ge_u32 = Stencil(
    "ge_u32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0x6b,  // CMP w0, w1 (32-bit)
        0xe0, 0x37, 0x9f, 0x1a   // CSET w0, hs (encode inverted LO=0011)
    ],
    []
);

immutable stencil_gt_i32 = Stencil(
    "gt_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0x6b,  // CMP w0, w1 (32-bit for signed comparison)
        0xe0, 0xd7, 0x9f, 0x1a   // CSET w0, gt
    ],
    []
);

immutable stencil_ge_i32 = Stencil(
    "ge_i32",
    cast(immutable ubyte[])[
        0x1f, 0x00, 0x01, 0x6b,  // CMP w0, w1 (32-bit for signed comparison)
        0xe0, 0xb7, 0x9f, 0x1a   // CSET w0, ge
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

// ----- Inline Call Stack Tracking -----
// These assume x10 = data section base

/**
 * Push a call frame onto the inline stack.
 * x10 = data section base (set by caller)
 * HOLE: frameDataOffset (16-bit immediate for MOVZ)
 * 
 * Stack layout at data section offset 0:
 *   [0]:  depth (i32)
 *   [4]:  maxDepth = 64
 *   [8]:  frames[64] (24 bytes each)
 */
immutable stencil_inline_stack_push = Stencil(
    "inline_stack_push",
    cast(immutable ubyte[])[
        // LDR w8, [x10]           ; load depth
        0x48, 0x01, 0x40, 0xB9,
        // CMP w8, #64             ; check overflow
        0x1F, 0x01, 0x01, 0x71,
        // B.GE +12                ; skip 12 instructions if depth >= 64
        0x8A, 0x01, 0x00, 0x54,
        
        // Calculate dest: x9 = x10 + 8 + depth * 24
        // MOVZ w9, #24
        0x09, 0x03, 0x80, 0x52,
        // MUL w9, w8, w9
        0x09, 0x7D, 0x09, 0x1B,
        // ADD x9, x10, x9
        0x49, 0x01, 0x09, 0x8B,
        // ADD x9, x9, #8
        0x29, 0x21, 0x00, 0x91,
        
        // Load source: x11 = x10 + frameDataOffset (HOLE at byte 28)
        // MOVZ x11, #0            ; HOLE: bits 5-20 = offset
        0x0B, 0x00, 0x80, 0xD2,
        // ADD x11, x10, x11
        0x4B, 0x01, 0x0B, 0x8B,
        
        // Copy 24 bytes from x11 to x9
        // LDP x12, x13, [x11]
        0x6C, 0x35, 0x40, 0xA9,
        // STP x12, x13, [x9]
        0x2C, 0x35, 0x00, 0xA9,
        // LDR x12, [x11, #16]
        0x6C, 0x09, 0x40, 0xF9,
        // STR x12, [x9, #16]
        0x2C, 0x09, 0x00, 0xF9,
        
        // Increment depth
        // ADD w8, w8, #1
        0x08, 0x05, 0x00, 0x11,
        // STR w8, [x10]
        0x48, 0x01, 0x00, 0xB9,
        // (skip label lands here - 16 instructions total)
    ],
    [
        // Hole at byte 28: frameDataOffset as 16-bit immediate in MOVZ
        // MOVZ encodes imm16 in bits 5-20
        StencilHole(28, HoleKind.imm16_0, 0)
    ]
);

/**
 * Pop a call frame from the inline stack.
 * x10 = data section base (set by caller)
 * No holes.
 */
immutable stencil_inline_stack_pop = Stencil(
    "inline_stack_pop",
    cast(immutable ubyte[])[
        // LDR w8, [x10]           ; load depth
        0x48, 0x01, 0x40, 0xB9,
        // SUBS w8, w8, #1         ; decrement (sets flags)
        0x08, 0x05, 0x00, 0x71,
        // B.LT +1                 ; skip store if underflow
        0x2B, 0x00, 0x00, 0x54,
        // STR w8, [x10]
        0x48, 0x01, 0x00, 0xB9,
    ],
    []
);

// ============================================================================
// Stencil Lookup Table
// ============================================================================

immutable Stencil*[string] stencilTable;

shared static this() {
    // Arithmetic
    stencilTable["add_i32"] = &stencil_add_i32;
    stencilTable["add_i64"] = &stencil_add_i64;
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
    stencilTable["lsr_i32"] = &stencil_lsr_i32;
    stencilTable["not_i32"] = &stencil_not_i32;
    
    // Logical
    stencilTable["logical_and_i32"] = &stencil_logical_and_i32;
    stencilTable["logical_or_i32"] = &stencil_logical_or_i32;

    // Comparison (signed)
    stencilTable["eq_i32"] = &stencil_eq_i32;
    stencilTable["ne_i32"] = &stencil_ne_i32;
    stencilTable["lt_i32"] = &stencil_lt_i32;
    stencilTable["le_i32"] = &stencil_le_i32;
    stencilTable["gt_i32"] = &stencil_gt_i32;
    stencilTable["ge_i32"] = &stencil_ge_i32;
    
    // Comparison (unsigned) - for bounds checking
    stencilTable["lt_u32"] = &stencil_lt_u32;
    stencilTable["ge_u32"] = &stencil_ge_u32;
    
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
    
    // Inline call stack tracking
    stencilTable["inline_stack_push"] = &stencil_inline_stack_push;
    stencilTable["inline_stack_pop"] = &stencil_inline_stack_pop;
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
