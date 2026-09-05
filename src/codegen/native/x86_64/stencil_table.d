/**
 * x86-64 Stencil Table
 *
 * Machine-code templates for the native x86-64 backend.
 * Register convention matches the ARM64 lowering's virtual ISA:
 *   rax = x0 (result / arg0 after SysV shuffle)
 *   rcx = x1 (arg1)
 *   rdx = x2
 *   rsi = x3
 *   r8  = x4
 *   r9  = x5
 *   r10 = x6
 *   rdi = x7
 *   r12 = x8 (temp)
 *   r11 = x9 (scratch)
 *   r13 = x10 (data-section base)
 *
 * i32 ops use 32-bit registers (eax/ecx) so values wrap like D `int`.
 */
module codegen.native.x86_64.stencil_table;

import codegen.native.stencil_catalog;

// ============================================================================
// Arithmetic  i32: eax = eax op ecx
// ============================================================================

immutable stencil_add_i32 = Stencil(
    "add_i32",
    cast(immutable ubyte[])[0x01, 0xC8],  // add eax, ecx
    []
);

immutable stencil_add_i64 = Stencil(
    "add_i64",
    cast(immutable ubyte[])[0x48, 0x01, 0xC8],  // add rax, rcx
    []
);

immutable stencil_sub_i32 = Stencil(
    "sub_i32",
    cast(immutable ubyte[])[0x29, 0xC8],  // sub eax, ecx
    []
);

immutable stencil_sub_i64 = Stencil(
    "sub_i64",
    cast(immutable ubyte[])[0x48, 0x29, 0xC8],  // sub rax, rcx
    []
);

immutable stencil_mul_i32 = Stencil(
    "mul_i32",
    cast(immutable ubyte[])[0x0F, 0xAF, 0xC1],  // imul eax, ecx
    []
);

immutable stencil_mul_i64 = Stencil(
    "mul_i64",
    cast(immutable ubyte[])[0x48, 0x0F, 0xAF, 0xC1],  // imul rax, rcx
    []
);

// idiv uses rdx:rax. Save/restore rdx (x2) around the divide.
immutable stencil_div_i32 = Stencil(
    "div_i32",
    cast(immutable ubyte[])[
        0x52,             // push rdx
        0x99,             // cdq
        0xF7, 0xF9,       // idiv ecx
        0x5A,             // pop rdx
    ],
    []
);

immutable stencil_div_i64 = Stencil(
    "div_i64",
    cast(immutable ubyte[])[
        0x52,                         // push rdx
        0x48, 0x99,                   // cqo
        0x48, 0xF7, 0xF9,             // idiv rcx
        0x5A,                         // pop rdx
    ],
    []
);

immutable stencil_mod_i32 = Stencil(
    "mod_i32",
    cast(immutable ubyte[])[
        0x52,             // push rdx
        0x99,             // cdq
        0xF7, 0xF9,       // idiv ecx
        0x89, 0xD0,       // mov eax, edx
        0x5A,             // pop rdx
    ],
    []
);

immutable stencil_mod_i64 = Stencil(
    "mod_i64",
    cast(immutable ubyte[])[
        0x52,                         // push rdx
        0x48, 0x99,                   // cqo
        0x48, 0xF7, 0xF9,             // idiv rcx
        0x48, 0x89, 0xD0,             // mov rax, rdx
        0x5A,                         // pop rdx
    ],
    []
);

immutable stencil_neg_i32 = Stencil(
    "neg_i32",
    cast(immutable ubyte[])[0xF7, 0xD8],  // neg eax
    []
);

// ============================================================================
// f64: xmm0 op xmm1 -> xmm0 ; comparisons write 0/1 to eax
// ============================================================================

immutable stencil_add_f64 = Stencil(
    "add_f64",
    cast(immutable ubyte[])[0xF2, 0x0F, 0x58, 0xC1],  // addsd xmm0, xmm1
    []
);

immutable stencil_sub_f64 = Stencil(
    "sub_f64",
    cast(immutable ubyte[])[0xF2, 0x0F, 0x5C, 0xC1],  // subsd xmm0, xmm1
    []
);

immutable stencil_mul_f64 = Stencil(
    "mul_f64",
    cast(immutable ubyte[])[0xF2, 0x0F, 0x59, 0xC1],  // mulsd xmm0, xmm1
    []
);

immutable stencil_div_f64 = Stencil(
    "div_f64",
    cast(immutable ubyte[])[0xF2, 0x0F, 0x5E, 0xC1],  // divsd xmm0, xmm1
    []
);

immutable stencil_neg_f64 = Stencil(
    "neg_f64",
    cast(immutable ubyte[])[
        0x48, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, // movabs rax, 0x8000000000000000
        0x66, 0x48, 0x0F, 0x6E, 0xC8,  // movq xmm1, rax
        0x66, 0x0F, 0x57, 0xC1,        // xorpd xmm0, xmm1
    ],
    []
);

private immutable ubyte[] cmpF64Eq = [
    0x66, 0x0F, 0x2F, 0xC1,  // comisd xmm0, xmm1
    0x0F, 0x94, 0xC0,        // sete al
    0x0F, 0xB6, 0xC0,        // movzx eax, al
];
private immutable ubyte[] cmpF64Ne = [
    0x66, 0x0F, 0x2F, 0xC1,
    0x0F, 0x95, 0xC0,
    0x0F, 0xB6, 0xC0,
];
private immutable ubyte[] cmpF64Lt = [
    0x66, 0x0F, 0x2F, 0xC1,
    0x0F, 0x92, 0xC0,        // setb (below = < for comisd)
    0x0F, 0xB6, 0xC0,
];
private immutable ubyte[] cmpF64Le = [
    0x66, 0x0F, 0x2F, 0xC1,
    0x0F, 0x96, 0xC0,        // setbe
    0x0F, 0xB6, 0xC0,
];
private immutable ubyte[] cmpF64Gt = [
    0x66, 0x0F, 0x2F, 0xC1,
    0x0F, 0x97, 0xC0,        // seta
    0x0F, 0xB6, 0xC0,
];
private immutable ubyte[] cmpF64Ge = [
    0x66, 0x0F, 0x2F, 0xC1,
    0x0F, 0x93, 0xC0,        // setae
    0x0F, 0xB6, 0xC0,
];

immutable stencil_eq_f64 = Stencil("eq_f64", cmpF64Eq, []);
immutable stencil_ne_f64 = Stencil("ne_f64", cmpF64Ne, []);
immutable stencil_lt_f64 = Stencil("lt_f64", cmpF64Lt, []);
immutable stencil_le_f64 = Stencil("le_f64", cmpF64Le, []);
immutable stencil_gt_f64 = Stencil("gt_f64", cmpF64Gt, []);
immutable stencil_ge_f64 = Stencil("ge_f64", cmpF64Ge, []);

immutable stencil_f64_to_i32 = Stencil(
    "f64_to_i32",
    cast(immutable ubyte[])[0xF2, 0x0F, 0x2C, 0xC0],  // cvttsd2si eax, xmm0
    []
);

immutable stencil_i32_to_f64 = Stencil(
    "i32_to_f64",
    cast(immutable ubyte[])[0xF2, 0x0F, 0x2A, 0xC0],  // cvtsi2sd xmm0, eax
    []
);

immutable stencil_move_d1_to_d0 = Stencil(
    "move_d1_to_d0",
    cast(immutable ubyte[])[0xF2, 0x0F, 0x10, 0xC1],  // movsd xmm0, xmm1
    []
);

immutable stencil_load_f64 = Stencil(
    "load_f64",
    cast(immutable ubyte[])[0xF2, 0x0F, 0x10, 0x00],  // movsd xmm0, [rax]
    []
);

immutable stencil_store_f64 = Stencil(
    "store_f64",
    cast(immutable ubyte[])[0xF2, 0x0F, 0x11, 0x00],  // movsd [rax], xmm0
    []
);

// ============================================================================
// Bitwise i32
// ============================================================================

immutable stencil_and_i32 = Stencil(
    "and_i32",
    cast(immutable ubyte[])[0x21, 0xC8],  // and eax, ecx
    []
);

immutable stencil_or_i32 = Stencil(
    "or_i32",
    cast(immutable ubyte[])[0x09, 0xC8],  // or eax, ecx
    []
);

immutable stencil_xor_i32 = Stencil(
    "xor_i32",
    cast(immutable ubyte[])[0x31, 0xC8],  // xor eax, ecx
    []
);

immutable stencil_not_i32 = Stencil(
    "not_i32",
    cast(immutable ubyte[])[0xF7, 0xD0],  // not eax
    []
);

// Shift count is already in cl (ecx = x1)
immutable stencil_shl_i32 = Stencil(
    "shl_i32",
    cast(immutable ubyte[])[0xD3, 0xE0],  // shl eax, cl
    []
);

immutable stencil_shl_i64 = Stencil(
    "shl_i64",
    cast(immutable ubyte[])[0x48, 0xD3, 0xE0],  // shl rax, cl
    []
);

immutable stencil_shr_i32 = Stencil(
    "shr_i32",
    cast(immutable ubyte[])[0xD3, 0xF8],  // sar eax, cl
    []
);

immutable stencil_shr_i64 = Stencil(
    "shr_i64",
    cast(immutable ubyte[])[0x48, 0xD3, 0xF8],  // sar rax, cl
    []
);

immutable stencil_lsr_i32 = Stencil(
    "lsr_i32",
    cast(immutable ubyte[])[0xD3, 0xE8],  // shr eax, cl
    []
);

immutable stencil_lsr_i64 = Stencil(
    "lsr_i64",
    cast(immutable ubyte[])[0x48, 0xD3, 0xE8],  // shr rax, cl
    []
);

immutable stencil_and_i64 = Stencil(
    "and_i64",
    cast(immutable ubyte[])[0x48, 0x21, 0xC8],
    []
);

immutable stencil_or_i64 = Stencil(
    "or_i64",
    cast(immutable ubyte[])[0x48, 0x09, 0xC8],
    []
);

immutable stencil_xor_i64 = Stencil(
    "xor_i64",
    cast(immutable ubyte[])[0x48, 0x31, 0xC8],
    []
);

// Logical && / || (truthy 0/1)
immutable stencil_logical_and_i32 = Stencil(
    "logical_and_i32",
    cast(immutable ubyte[])[
        0x85, 0xC0,              // test eax, eax
        0x0F, 0x95, 0xC0,        // setne al
        0x0F, 0xB6, 0xC0,        // movzx eax, al
        0x85, 0xC9,              // test ecx, ecx
        0x0F, 0x95, 0xC1,        // setne cl
        0x0F, 0xB6, 0xC9,        // movzx ecx, cl
        0x21, 0xC8,              // and eax, ecx
    ],
    []
);

immutable stencil_logical_or_i32 = Stencil(
    "logical_or_i32",
    cast(immutable ubyte[])[
        0x85, 0xC0,
        0x0F, 0x95, 0xC0,
        0x0F, 0xB6, 0xC0,
        0x85, 0xC9,
        0x0F, 0x95, 0xC1,
        0x0F, 0xB6, 0xC9,
        0x09, 0xC8,              // or eax, ecx
    ],
    []
);

// ============================================================================
// Integer comparisons: cmp eax,ecx / setcc / movzx
// ============================================================================

private immutable ubyte[] cmpI32Eq = [0x39, 0xC8, 0x0F, 0x94, 0xC0, 0x0F, 0xB6, 0xC0];
private immutable ubyte[] cmpI32Ne = [0x39, 0xC8, 0x0F, 0x95, 0xC0, 0x0F, 0xB6, 0xC0];
private immutable ubyte[] cmpI32Lt = [0x39, 0xC8, 0x0F, 0x9C, 0xC0, 0x0F, 0xB6, 0xC0]; // setl
private immutable ubyte[] cmpI32Le = [0x39, 0xC8, 0x0F, 0x9E, 0xC0, 0x0F, 0xB6, 0xC0]; // setle
private immutable ubyte[] cmpI32Gt = [0x39, 0xC8, 0x0F, 0x9F, 0xC0, 0x0F, 0xB6, 0xC0]; // setg
private immutable ubyte[] cmpI32Ge = [0x39, 0xC8, 0x0F, 0x9D, 0xC0, 0x0F, 0xB6, 0xC0]; // setge
private immutable ubyte[] cmpI32LtU = [0x39, 0xC8, 0x0F, 0x92, 0xC0, 0x0F, 0xB6, 0xC0]; // setb
private immutable ubyte[] cmpI32GeU = [0x39, 0xC8, 0x0F, 0x93, 0xC0, 0x0F, 0xB6, 0xC0]; // setae

immutable stencil_eq_i32 = Stencil("eq_i32", cmpI32Eq, []);
immutable stencil_ne_i32 = Stencil("ne_i32", cmpI32Ne, []);
immutable stencil_lt_i32 = Stencil("lt_i32", cmpI32Lt, []);
immutable stencil_le_i32 = Stencil("le_i32", cmpI32Le, []);
immutable stencil_gt_i32 = Stencil("gt_i32", cmpI32Gt, []);
immutable stencil_ge_i32 = Stencil("ge_i32", cmpI32Ge, []);
immutable stencil_lt_u32 = Stencil("lt_u32", cmpI32LtU, []);
immutable stencil_ge_u32 = Stencil("ge_u32", cmpI32GeU, []);

private immutable ubyte[] cmpI64Eq = [0x48, 0x39, 0xC8, 0x0F, 0x94, 0xC0, 0x0F, 0xB6, 0xC0];
private immutable ubyte[] cmpI64Ne = [0x48, 0x39, 0xC8, 0x0F, 0x95, 0xC0, 0x0F, 0xB6, 0xC0];
private immutable ubyte[] cmpI64Lt = [0x48, 0x39, 0xC8, 0x0F, 0x9C, 0xC0, 0x0F, 0xB6, 0xC0];
private immutable ubyte[] cmpI64Le = [0x48, 0x39, 0xC8, 0x0F, 0x9E, 0xC0, 0x0F, 0xB6, 0xC0];
private immutable ubyte[] cmpI64Gt = [0x48, 0x39, 0xC8, 0x0F, 0x9F, 0xC0, 0x0F, 0xB6, 0xC0];
private immutable ubyte[] cmpI64Ge = [0x48, 0x39, 0xC8, 0x0F, 0x9D, 0xC0, 0x0F, 0xB6, 0xC0];

immutable stencil_eq_i64 = Stencil("eq_i64", cmpI64Eq, []);
immutable stencil_ne_i64 = Stencil("ne_i64", cmpI64Ne, []);
immutable stencil_lt_i64 = Stencil("lt_i64", cmpI64Lt, []);
immutable stencil_le_i64 = Stencil("le_i64", cmpI64Le, []);
immutable stencil_gt_i64 = Stencil("gt_i64", cmpI64Gt, []);
immutable stencil_ge_i64 = Stencil("ge_i64", cmpI64Ge, []);

// ============================================================================
// Immediates
// ============================================================================

immutable stencil_load_imm32 = Stencil(
    "load_imm32",
    cast(immutable ubyte[])[0xB8, 0x00, 0x00, 0x00, 0x00],  // mov eax, imm32
    [StencilHole(1, HoleKind.imm32, 0)]
);

immutable stencil_load_imm64 = Stencil(
    "load_imm64",
    cast(immutable ubyte[])[0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0],  // movabs rax, imm64
    [StencilHole(2, HoleKind.imm64, 0)]
);

immutable stencil_load_imm64_to_scratch = Stencil(
    "load_imm64_to_scratch",
    cast(immutable ubyte[])[0x49, 0xBB, 0, 0, 0, 0, 0, 0, 0, 0],  // movabs r11, imm64
    [StencilHole(2, HoleKind.imm64, 0)]
);

// ============================================================================
// Memory  [rax + 0]
// ============================================================================

immutable stencil_load_i32 = Stencil(
    "load_i32",
    cast(immutable ubyte[])[0x8B, 0x00],  // mov eax, [rax]
    []
);

immutable stencil_store_i32 = Stencil(
    "store_i32",
    cast(immutable ubyte[])[0x89, 0x08],  // mov [rax], ecx
    []
);

immutable stencil_load_i64 = Stencil(
    "load_i64",
    cast(immutable ubyte[])[0x48, 0x8B, 0x00],  // mov rax, [rax]
    []
);

immutable stencil_store_i64 = Stencil(
    "store_i64",
    cast(immutable ubyte[])[0x48, 0x89, 0x08],  // mov [rax], rcx
    []
);

// Locals are emitted by NativeCodeGen (RBP-relative), not these stencils.
immutable stencil_load_local_i32 = Stencil("load_local_i32", cast(immutable ubyte[])[0x90], []);
immutable stencil_store_local_i32 = Stencil("store_local_i32", cast(immutable ubyte[])[0x90], []);
immutable stencil_load_local_i64 = Stencil("load_local_i64", cast(immutable ubyte[])[0x90], []);
immutable stencil_store_local_i64 = Stencil("store_local_i64", cast(immutable ubyte[])[0x90], []);
immutable stencil_inc_local_i32 = Stencil("inc_local_i32", cast(immutable ubyte[])[0x90], []);
immutable stencil_store_arg1_to_local_i32 = Stencil("store_arg1_to_local_i32", cast(immutable ubyte[])[0x90], []);
immutable stencil_store_arg2_to_local_i32 = Stencil("store_arg2_to_local_i32", cast(immutable ubyte[])[0x90], []);
immutable stencil_store_arg3_to_local_i32 = Stencil("store_arg3_to_local_i32", cast(immutable ubyte[])[0x90], []);

immutable stencil_load_ptr_indirect = Stencil(
    "load_ptr_indirect",
    cast(immutable ubyte[])[0x4D, 0x8B, 0x1B],  // mov r11, [r11]
    []
);

immutable stencil_call_indirect = Stencil(
    "call_indirect",
    cast(immutable ubyte[])[0x41, 0xFF, 0xD3],  // call r11
    []
);

immutable stencil_prologue = Stencil("prologue", cast(immutable ubyte[])[0x90], []);
immutable stencil_prologue_with_locals = Stencil("prologue_with_locals", cast(immutable ubyte[])[0x90], []);
immutable stencil_epilogue = Stencil("epilogue", cast(immutable ubyte[])[0x90], []);
immutable stencil_epilogue_with_locals = Stencil("epilogue_with_locals", cast(immutable ubyte[])[0x90], []);

immutable stencil_move_result_to_arg1 = Stencil(
    "move_result_to_arg1",
    cast(immutable ubyte[])[0x48, 0x89, 0xC1],  // mov rcx, rax
    []
);
immutable stencil_move_result_to_arg2 = Stencil(
    "move_result_to_arg2",
    cast(immutable ubyte[])[0x48, 0x89, 0xC2],  // mov rdx, rax
    []
);
immutable stencil_move_result_to_arg3 = Stencil(
    "move_result_to_arg3",
    cast(immutable ubyte[])[0x48, 0x89, 0xC6],  // mov rsi, rax
    []
);
immutable stencil_move_result_to_scratch = Stencil(
    "move_result_to_scratch",
    cast(immutable ubyte[])[0x49, 0x89, 0xC3],  // mov r11, rax
    []
);
immutable stencil_move_scratch_to_result = Stencil(
    "move_scratch_to_result",
    cast(immutable ubyte[])[0x4C, 0x89, 0xD8],  // mov rax, r11
    []
);
immutable stencil_move_arg1_to_result = Stencil(
    "move_arg1_to_result",
    cast(immutable ubyte[])[0x48, 0x89, 0xC8],  // mov rax, rcx
    []
);
immutable stencil_move_arg2_to_arg1 = Stencil(
    "move_arg2_to_arg1",
    cast(immutable ubyte[])[0x48, 0x89, 0xD1],  // mov rcx, rdx
    []
);
immutable stencil_move_result_to_scratch2 = Stencil(
    "move_result_to_scratch2",
    cast(immutable ubyte[])[0x49, 0x89, 0xC4],  // mov r12, rax
    []
);
immutable stencil_move_scratch2_to_result = Stencil(
    "move_scratch2_to_result",
    cast(immutable ubyte[])[0x4C, 0x89, 0xE0],  // mov rax, r12
    []
);

immutable stencil_get_frame_pointer = Stencil(
    "get_frame_pointer",
    cast(immutable ubyte[])[0x48, 0x89, 0xE8],  // mov rax, rbp
    []
);

immutable stencil_return_void = Stencil(
    "return_void",
    cast(immutable ubyte[])[0xC3],
    []
);

immutable stencil_return_val = Stencil(
    "return_val",
    cast(immutable ubyte[])[0xC3],
    []
);

// Inline stack push/pop are emitted by NativeCodeGen (variable-length).
immutable stencil_inline_stack_push = Stencil("inline_stack_push", cast(immutable ubyte[])[0x90], []);
immutable stencil_inline_stack_pop = Stencil("inline_stack_pop", cast(immutable ubyte[])[0x90], []);

// ============================================================================
// Lookup
// ============================================================================

immutable Stencil*[string] stencilTable;

shared static this() {
    stencilTable["add_i32"] = &stencil_add_i32;
    stencilTable["add_i64"] = &stencil_add_i64;
    stencilTable["sub_i32"] = &stencil_sub_i32;
    stencilTable["sub_i64"] = &stencil_sub_i64;
    stencilTable["mul_i32"] = &stencil_mul_i32;
    stencilTable["mul_i64"] = &stencil_mul_i64;
    stencilTable["div_i32"] = &stencil_div_i32;
    stencilTable["div_i64"] = &stencil_div_i64;
    stencilTable["mod_i32"] = &stencil_mod_i32;
    stencilTable["mod_i64"] = &stencil_mod_i64;
    stencilTable["neg_i32"] = &stencil_neg_i32;
    stencilTable["add_f64"] = &stencil_add_f64;
    stencilTable["sub_f64"] = &stencil_sub_f64;
    stencilTable["mul_f64"] = &stencil_mul_f64;
    stencilTable["div_f64"] = &stencil_div_f64;
    stencilTable["neg_f64"] = &stencil_neg_f64;
    stencilTable["eq_f64"] = &stencil_eq_f64;
    stencilTable["ne_f64"] = &stencil_ne_f64;
    stencilTable["lt_f64"] = &stencil_lt_f64;
    stencilTable["le_f64"] = &stencil_le_f64;
    stencilTable["gt_f64"] = &stencil_gt_f64;
    stencilTable["ge_f64"] = &stencil_ge_f64;
    stencilTable["f64_to_i32"] = &stencil_f64_to_i32;
    stencilTable["i32_to_f64"] = &stencil_i32_to_f64;
    stencilTable["move_d1_to_d0"] = &stencil_move_d1_to_d0;
    stencilTable["load_f64"] = &stencil_load_f64;
    stencilTable["store_f64"] = &stencil_store_f64;
    stencilTable["and_i32"] = &stencil_and_i32;
    stencilTable["or_i32"] = &stencil_or_i32;
    stencilTable["xor_i32"] = &stencil_xor_i32;
    stencilTable["shl_i32"] = &stencil_shl_i32;
    stencilTable["shl_i64"] = &stencil_shl_i64;
    stencilTable["shr_i32"] = &stencil_shr_i32;
    stencilTable["shr_i64"] = &stencil_shr_i64;
    stencilTable["lsr_i32"] = &stencil_lsr_i32;
    stencilTable["lsr_i64"] = &stencil_lsr_i64;
    stencilTable["and_i64"] = &stencil_and_i64;
    stencilTable["or_i64"] = &stencil_or_i64;
    stencilTable["xor_i64"] = &stencil_xor_i64;
    stencilTable["not_i32"] = &stencil_not_i32;
    stencilTable["logical_and_i32"] = &stencil_logical_and_i32;
    stencilTable["logical_or_i32"] = &stencil_logical_or_i32;
    stencilTable["eq_i32"] = &stencil_eq_i32;
    stencilTable["ne_i32"] = &stencil_ne_i32;
    stencilTable["lt_i32"] = &stencil_lt_i32;
    stencilTable["le_i32"] = &stencil_le_i32;
    stencilTable["gt_i32"] = &stencil_gt_i32;
    stencilTable["ge_i32"] = &stencil_ge_i32;
    stencilTable["eq_i64"] = &stencil_eq_i64;
    stencilTable["ne_i64"] = &stencil_ne_i64;
    stencilTable["lt_i64"] = &stencil_lt_i64;
    stencilTable["le_i64"] = &stencil_le_i64;
    stencilTable["gt_i64"] = &stencil_gt_i64;
    stencilTable["ge_i64"] = &stencil_ge_i64;
    stencilTable["lt_u32"] = &stencil_lt_u32;
    stencilTable["ge_u32"] = &stencil_ge_u32;
    stencilTable["load_imm32"] = &stencil_load_imm32;
    stencilTable["load_imm64"] = &stencil_load_imm64;
    stencilTable["load_imm64_to_scratch"] = &stencil_load_imm64_to_scratch;
    stencilTable["load_i32"] = &stencil_load_i32;
    stencilTable["store_i32"] = &stencil_store_i32;
    stencilTable["load_i64"] = &stencil_load_i64;
    stencilTable["store_i64"] = &stencil_store_i64;
    stencilTable["load_local_i32"] = &stencil_load_local_i32;
    stencilTable["store_local_i32"] = &stencil_store_local_i32;
    stencilTable["load_local_i64"] = &stencil_load_local_i64;
    stencilTable["store_local_i64"] = &stencil_store_local_i64;
    stencilTable["inc_local_i32"] = &stencil_inc_local_i32;
    stencilTable["load_ptr_indirect"] = &stencil_load_ptr_indirect;
    stencilTable["call_indirect"] = &stencil_call_indirect;
    stencilTable["prologue"] = &stencil_prologue;
    stencilTable["prologue_with_locals"] = &stencil_prologue_with_locals;
    stencilTable["epilogue"] = &stencil_epilogue;
    stencilTable["epilogue_with_locals"] = &stencil_epilogue_with_locals;
    stencilTable["move_result_to_arg1"] = &stencil_move_result_to_arg1;
    stencilTable["move_result_to_arg2"] = &stencil_move_result_to_arg2;
    stencilTable["move_result_to_arg3"] = &stencil_move_result_to_arg3;
    stencilTable["move_result_to_scratch"] = &stencil_move_result_to_scratch;
    stencilTable["move_scratch_to_result"] = &stencil_move_scratch_to_result;
    stencilTable["move_arg1_to_result"] = &stencil_move_arg1_to_result;
    stencilTable["move_arg2_to_arg1"] = &stencil_move_arg2_to_arg1;
    stencilTable["move_result_to_scratch2"] = &stencil_move_result_to_scratch2;
    stencilTable["move_scratch2_to_result"] = &stencil_move_scratch2_to_result;
    stencilTable["store_arg1_to_local_i32"] = &stencil_store_arg1_to_local_i32;
    stencilTable["store_arg2_to_local_i32"] = &stencil_store_arg2_to_local_i32;
    stencilTable["store_arg3_to_local_i32"] = &stencil_store_arg3_to_local_i32;
    stencilTable["get_frame_pointer"] = &stencil_get_frame_pointer;
    stencilTable["return_void"] = &stencil_return_void;
    stencilTable["return_val"] = &stencil_return_val;
    stencilTable["inline_stack_push"] = &stencil_inline_stack_push;
    stencilTable["inline_stack_pop"] = &stencil_inline_stack_pop;
}

const(Stencil)* getStencil(string name) {
    if (auto p = name in stencilTable) return *p;
    return null;
}
