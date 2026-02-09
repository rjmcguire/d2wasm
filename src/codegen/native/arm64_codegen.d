/**
 * Native Code Generator using Copy-and-Patch
 * 
 * Provides a higher-level interface for emitting native ARM64 code
 * using pre-compiled stencils with runtime patching.
 * 
 * Source: ~/projects/copy-patch-arm64/
 */
module codegen.native.arm64_codegen;

import codegen.native.stencil_catalog;
import codegen.native.arm64.stencil_table;
import codegen.native.codegen_interface : Label, NativeDataSection, NativeCTFEContext, 
    HostFunctionPtr, HostFunctionTable, CTFEErrorKind, ctfeErrorMessage, longjmp;
import core.sys.posix.sys.mman;
import core.stdc.string : memcpy;

// macOS-specific mmap flags
version (OSX) {
    import codegen.native.codegen_interface : MAP_ANONYMOUS, MAP_JIT;
}

/// Unresolved branch that needs patching
struct UnresolvedBranch {
    uint offset;     // Where the branch instruction is
    int labelId;     // Target label
    BranchKind kind;
}

enum BranchKind {
    unconditional,   // B
    ifZero,          // CBZ
    ifNonZero,       // CBNZ
    call,            // BL
    conditional,     // B.cond (condition in bits 0-3)
}

/// ARM64 Native Code Generator
struct NativeCodeGen {
    ubyte* base;
    size_t capacity;
    size_t offset;
    
    // Label management
    Label[] labels;
    UnresolvedBranch[] unresolved;
    int nextLabelId;
    
    /// Allocate a code buffer
    static NativeCodeGen alloc(size_t size) {
        void* mem = mmap(null, size,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT,
            -1, 0);
        
        if (mem == MAP_FAILED) return NativeCodeGen.init;
        return NativeCodeGen(cast(ubyte*)mem, size, 0);
    }
    
    /// Current position in buffer
    @property uint pos() { return cast(uint)offset; }
    
    // ========== Stencil Emission ==========
    
    /// Emit raw bytes
    void* emitBytes(const(ubyte)[] bytes) {
        if (offset + bytes.length > capacity) return null;
        void* addr = base + offset;
        memcpy(addr, bytes.ptr, bytes.length);
        offset += bytes.length;
        return addr;
    }
    
    /// Emit a stencil without patching
    void* emit(const ref Stencil s) {
        return emitBytes(s.code);
    }
    
    /// Emit stencil with 32-bit immediate patched
    void* emitImm32(const ref Stencil s, int value) {
        void* addr = emit(s);
        if (!addr) return null;
        
        foreach (ref hole; s.holes) {
            uint* instr = cast(uint*)(cast(ubyte*)addr + hole.offset);
            // Patch based on hole kind - imm16_0/1 for 32-bit immediates
            switch (hole.kind) {
                case HoleKind.imm16_0:
                    *instr = (*instr & 0xFFE0001F) | ((value & 0xFFFF) << 5);
                    break;
                case HoleKind.imm16_1:
                    *instr = (*instr & 0xFFE0001F) | (((value >> 16) & 0xFFFF) << 5);
                    break;
                default:
                    // Other hole kinds not used for 32-bit immediates
                    break;
            }
        }
        return addr;
    }
    
    // ========== Arithmetic (from stencils) ==========
    
    void emitAdd() { emit(stencil_add_i32); }
    void emitSub() { emit(stencil_sub_i32); }
    void emitMul() { emit(stencil_mul_i32); }
    void emitDiv() { emit(stencil_div_i32); }
    void emitMod() { emit(stencil_mod_i32); }
    
    void emitAnd() { emit(stencil_and_i32); }
    void emitOr()  { emit(stencil_or_i32); }
    void emitXor() { emit(stencil_xor_i32); }
    void emitShl() { emit(stencil_shl_i32); }
    void emitShr() { emit(stencil_shr_i32); }
    
    void emitEq() { emit(stencil_eq_i32); }
    void emitNe() { emit(stencil_ne_i32); }
    void emitLt() { emit(stencil_lt_i32); }
    void emitLe() { emit(stencil_le_i32); }
    void emitGt() { emit(stencil_gt_i32); }
    void emitGe() { emit(stencil_ge_i32); }
    
    void emitLoadImm(int value) { emitImm32(stencil_load_imm32, value); }
    void emitRet() { emit(stencil_return_val); }
    
    /// Load a 64-bit immediate into x0
    /// Uses MOV + 3 MOVK instructions (16 bytes total)
    void emitLoadImm64(ulong value) {
        // ARM64 encoding for loading 64-bit immediate into x0:
        // MOV x0, #imm16          (bits 0-15)   : 0xD2800000 | (imm16 << 5)
        // MOVK x0, #imm16, LSL 16 (bits 16-31) : 0xF2A00000 | (imm16 << 5)
        // MOVK x0, #imm16, LSL 32 (bits 32-47) : 0xF2C00000 | (imm16 << 5)
        // MOVK x0, #imm16, LSL 48 (bits 48-63) : 0xF2E00000 | (imm16 << 5)
        
        ushort imm0 = cast(ushort)(value & 0xFFFF);
        ushort imm1 = cast(ushort)((value >> 16) & 0xFFFF);
        ushort imm2 = cast(ushort)((value >> 32) & 0xFFFF);
        ushort imm3 = cast(ushort)((value >> 48) & 0xFFFF);
        
        // Always emit all 4 instructions for correctness
        // (Could optimize later to skip trailing zero MOVK)
        emitRaw32(0xD2800000 | (cast(uint)imm0 << 5));  // MOV x0, #imm0
        emitRaw32(0xF2A00000 | (cast(uint)imm1 << 5));  // MOVK x0, #imm1, LSL 16
        emitRaw32(0xF2C00000 | (cast(uint)imm2 << 5));  // MOVK x0, #imm2, LSL 32
        emitRaw32(0xF2E00000 | (cast(uint)imm3 << 5));  // MOVK x0, #imm3, LSL 48
    }
    
    // ========== Indirect Calls (Milestone 88) ==========
    
    /// Load a 64-bit immediate into x9 (scratch register for indirect calls)
    /// This preserves x0-x3 which may contain arguments
    void emitLoadImm64ToX9(ulong value) {
        // Same as emitLoadImm64 but targeting x9 instead of x0
        // x9 encoding = register bits 0-4 = 9 = 0b01001
        ushort imm0 = cast(ushort)(value & 0xFFFF);
        ushort imm1 = cast(ushort)((value >> 16) & 0xFFFF);
        ushort imm2 = cast(ushort)((value >> 32) & 0xFFFF);
        ushort imm3 = cast(ushort)((value >> 48) & 0xFFFF);
        
        emitRaw32(0xD2800009 | (cast(uint)imm0 << 5));  // MOV x9, #imm0
        emitRaw32(0xF2A00009 | (cast(uint)imm1 << 5));  // MOVK x9, #imm1, LSL 16
        emitRaw32(0xF2C00009 | (cast(uint)imm2 << 5));  // MOVK x9, #imm2, LSL 32
        emitRaw32(0xF2E00009 | (cast(uint)imm3 << 5));  // MOVK x9, #imm3, LSL 48
    }
    
    /// Load 64-bit value from address in x9 into x9
    /// LDR x9, [x9]
    void emitLoadFromX9() {
        // LDR x9, [x9] = 0xF9400129
        // Encoding: 1111 1001 01 000000 000000 01001 01001
        //           size=11 opc=01 imm12=0 Rn=x9 Rt=x9
        emitRaw32(0xF9400129);
    }
    
    /// Load 32-bit value from [x9 + offset] into x0
    void emitLoadFromX9Offset(uint offset) {
        // LDR w0, [x9, #offset]
        uint imm12 = offset / 4;  // Scaled offset for 32-bit load
        emitRaw32(0xB9400120 | (imm12 << 10));  // LDR w0, [x9, #imm]
    }
    
    /// Move x0 to x9
    void emitMoveX0ToX9() {
        // MOV x9, x0 = ORR x9, xzr, x0
        emitRaw32(0xAA0003E9);
    }
    
    /// Move x1 to x9
    void emitMoveX1ToX9() {
        // MOV x9, x1 = ORR x9, xzr, x1
        emitRaw32(0xAA0103E9);
    }
    
    /// Move x2 to x9
    void emitMoveX2ToX9() {
        // MOV x9, x2 = ORR x9, xzr, x2
        emitRaw32(0xAA0203E9);
    }
    
    /// Move x3 to x9
    void emitMoveX3ToX9() {
        // MOV x9, x3 = ORR x9, xzr, x3
        emitRaw32(0xAA0303E9);
    }
    
    /// Compute x0 = SP + offset (for getting address of stack variable)
    void emitStackAddress(uint offset) {
        // ADD x0, sp, #offset
        // Encoding: 1001 0001 00 [imm12] [11111] [00000]
        //           sf=1 op=0 S=0 imm12 Rn=sp Rd=x0
        if (offset < 4096) {
            emitRaw32(0x910003E0 | (offset << 10));
        } else {
            // For larger offsets, use MOV + ADD
            emitLoadImm64(offset);          // x0 = offset
            emitRaw32(0x8B0003E0);           // ADD x0, sp, x0
        }
    }
    
    /// Call function at address in x9 (BLR x9)
    void emitCallIndirectX9() {
        // BLR x9 = 0xD63F0120
        // Encoding: 1101 0110 0011 1111 0000 0001 0010 0000
        //           BLR Rn where Rn=x9 (bits 5-9 = 01001)
        emitRaw32(0xD63F0120);
    }
    
    /// Emit a complete indirect call through a function pointer slot
    /// slotAddress = address of the function pointer in memory
    /// Arguments should already be set up in x0-x3
    void emitIndirectCall(ulong slotAddress) {
        emitLoadImm64ToX9(slotAddress);  // x9 = address of function pointer
        emitLoadFromX9();                 // x9 = *x9 (actual function pointer)
        emitCallIndirectX9();             // call x9
    }
    
    /// Emit a host function call with automatic context injection
    /// funcSlotAddress = address of the function pointer in memory
    /// contextSlotAddress = address of the NativeCTFEContext* in memory
    /// Arguments should already be set up in x0-x2 (they get shifted to x1-x3)
    void emitHostCall(ulong funcSlotAddress, ulong contextSlotAddress) {
        // Shift args: x0->x1, x1->x2, x2->x3 (x3 is lost, but we only support 3 args)
        emitMoveX2ToX3();
        emitMoveX1ToX2();
        emitMoveX0ToX1();
        
        // Load context pointer into x0
        emitLoadImm64ToX9(contextSlotAddress);  // x9 = address of context pointer
        emitLoadFromX9();                        // x9 = *x9 (actual context pointer)
        emit(stencil_move_scratch_to_result);    // x0 = x9 (context)
        
        // Load function pointer and call
        emitLoadImm64ToX9(funcSlotAddress);     // x9 = address of function pointer
        emitLoadFromX9();                        // x9 = *x9 (actual function pointer)
        emitCallIndirectX9();                    // call x9
    }
    
    // ========== Branch Instructions ==========
    
    /// Create a new label (not yet placed)
    Label newLabel() {
        auto label = Label(nextLabelId++, false, 0);
        labels ~= label;
        return label;
    }
    
    /// Bind a label to the current position
    void bindLabel(ref Label label) {
        label.bound = true;
        label.offset = pos;
        // Update in our array too
        foreach (ref l; labels) {
            if (l.id == label.id) {
                l.bound = true;
                l.offset = pos;
                break;
            }
        }
    }
    
    /// Emit unconditional branch (B)
    void emitBranch(Label target) {
        uint branchOffset = pos;
        // Emit placeholder: B +0
        emitRaw32(0x14000000);
        unresolved ~= UnresolvedBranch(branchOffset, target.id, BranchKind.unconditional);
    }
    
    /// Emit branch if x0 == 0 (CBZ w0, target)
    void emitBranchIfZero(Label target) {
        uint branchOffset = pos;
        // Emit placeholder: CBZ w0, +0
        emitRaw32(0x34000000);  // CBZ w0
        unresolved ~= UnresolvedBranch(branchOffset, target.id, BranchKind.ifZero);
    }
    
    /// Emit branch if x0 != 0 (CBNZ w0, target)
    void emitBranchIfNonZero(Label target) {
        uint branchOffset = pos;
        // Emit placeholder: CBNZ w0, +0
        emitRaw32(0x35000000);  // CBNZ w0
        unresolved ~= UnresolvedBranch(branchOffset, target.id, BranchKind.ifNonZero);
    }
    
    /// Emit branch if x1 == 0 (CBZ w1, target) - for checking divisor
    void emitBranchIfZeroX1(Label target) {
        uint branchOffset = pos;
        // Emit placeholder: CBZ w1, +0  (register 1 in bits 0-4)
        emitRaw32(0x34000001);  // CBZ w1
        unresolved ~= UnresolvedBranch(branchOffset, target.id, BranchKind.ifZero);
    }
    
    /// Emit raw 32-bit instruction
    void emitRaw32(uint instr) {
        if (offset + 4 > capacity) return;
        *cast(uint*)(base + offset) = instr;
        offset += 4;
    }
    
    // ========== Function Calls ==========
    
    /// Emit BL (branch with link) to a label
    void emitCall(Label target) {
        uint callOffset = pos;
        // BL: 0x94000000 | imm26
        emitRaw32(0x94000000);
        unresolved ~= UnresolvedBranch(callOffset, target.id, BranchKind.call);
    }
    
    /// Emit BLR (branch with link to register) - call function pointer in x8
    void emitCallIndirect() {
        // BLR x8: 0xD63F0100
        emitRaw32(0xD63F0100);
    }
    
    /// Move x0 to x1 (for binary op: first arg to second position)
    void emitMoveX0ToX1() {
        // MOV x1, x0: really ORR x1, xzr, x0 = 0xAA0003E1
        emitRaw32(0xAA0003E1);
    }
    
    /// Move x0 to x2 (for function arg 2)
    void emitMoveX0ToX2() {
        // MOV x2, x0: ORR x2, xzr, x0 = 0xAA0003E2
        emitRaw32(0xAA0003E2);
    }
    
    /// Move x0 to x3 (for function arg 3)
    void emitMoveX0ToX3() {
        // MOV x3, x0: ORR x3, xzr, x0 = 0xAA0003E3
        emitRaw32(0xAA0003E3);
    }
    
    /// Move x0 to x8 (for saving across calls)
    void emitMoveX0ToX8() {
        // MOV x8, x0: ORR x8, xzr, x0 = 0xAA0003E8
        emitRaw32(0xAA0003E8);
    }
    
    /// Move x8 to x0 (restore after calls)
    void emitMoveX8ToX0() {
        // MOV x0, x8: ORR x0, xzr, x8 = 0xAA0803E0
        emitRaw32(0xAA0803E0);
    }
    
    /// Move x1 to x0
    void emitMoveX1ToX0() {
        // MOV x0, x1: ORR x0, xzr, x1 = 0xAA0103E0
        emitRaw32(0xAA0103E0);
    }
    
    /// Move x2 to x1
    void emitMoveX2ToX1() {
        // MOV x1, x2: ORR x1, xzr, x2 = 0xAA0203E1
        emitRaw32(0xAA0203E1);
    }
    
    /// Move x1 to x2
    void emitMoveX1ToX2() {
        // MOV x2, x1: ORR x2, xzr, x1 = 0xAA0103E2
        emitRaw32(0xAA0103E2);
    }
    
    /// Move x2 to x3
    void emitMoveX2ToX3() {
        // MOV x3, x2: ORR x3, xzr, x2 = 0xAA0203E3
        emitRaw32(0xAA0203E3);
    }
    
    /// Move x0 to x10 (for data section base)
    void emitMoveX0ToX10() {
        // MOV x10, x0: ORR x10, xzr, x0 = 0xAA0003EA
        emitRaw32(0xAA0003EA);
    }
    
    /// Move x10 to x0
    void emitMoveX10ToX0() {
        // MOV x0, x10: ORR x0, xzr, x10 = 0xAA0A03E0
        emitRaw32(0xAA0A03E0);
    }
    
    // ========== Inline Call Stack (no FFI) ==========
    // These methods emit inline code to track the call stack directly
    // in the data section, avoiding expensive FFI crossings.
    //
    // Data section layout at offset 0:
    //   [0]:  depth (i32)
    //   [4]:  maxDepth (i32) = 64
    //   [8]:  frames[64] - array of InlineFrame (24 bytes each)
    //
    // x10 must contain the data section base address
    
    /// Emit inline call stack push using stencil
    /// x10 = data section base (set by caller)
    /// frameDataOffset = offset in data section where InlineFrame is stored
    void emitInlineStackPush(uint frameDataOffset) {
        // Use the stencil with frameDataOffset patched into the MOVZ hole
        emitImm32(stencil_inline_stack_push, cast(int)frameDataOffset);
    }
    
    /// Emit inline call stack pop using stencil
    /// x10 = data section base (set by caller)
    void emitInlineStackPop() {
        emit(stencil_inline_stack_pop);
    }
    
    /// Emit B.GE (branch if greater or equal) to label
    void emitBranchIfGE(Label target) {
        uint branchOffset = pos;
        emitRaw32(0x5400000A);  // B.GE placeholder (cond = 0xA for GE)
        unresolved ~= UnresolvedBranch(branchOffset, target.id, BranchKind.conditional);
    }
    
    // ===== Abstract Aliases (for architecture-agnostic code) =====
    // These map abstract operation names to ARM64-specific implementations
    
    alias emitMoveResultToArg1 = emitMoveX0ToX1;
    alias emitMoveResultToArg2 = emitMoveX0ToX2;
    alias emitMoveResultToArg3 = emitMoveX0ToX3;
    alias emitMoveResultToScratch2 = emitMoveX0ToX8;
    alias emitMoveScratch2ToResult = emitMoveX8ToX0;
    alias emitMoveArg1ToResult = emitMoveX1ToX0;
    alias emitMoveArg2ToArg1 = emitMoveX2ToX1;
    
    /// Push x30 (link register) - needed before calling functions
    void emitPushLR() {
        // STR x30, [sp, #-16]!  (pre-index, 16-byte aligned)
        // = 0xF81F0FFE
        emitRaw32(0xF81F0FFE);
    }
    
    /// Pop x30 (link register) - restore after function calls
    void emitPopLR() {
        // LDR x30, [sp], #16  (post-index)
        // = 0xF84107FE
        emitRaw32(0xF84107FE);
    }
    
    /// Push a register to stack (16-byte aligned)
    void emitPush(int reg) {
        // STR x<reg>, [sp, #-16]!
        // Base: 0xF81F0FE0, reg in bits 0-4
        emitRaw32(0xF81F0FE0 | reg);
    }
    
    /// Pop a register from stack (16-byte aligned)
    void emitPop(int reg) {
        // LDR x<reg>, [sp], #16
        // Base: 0xF84107E0, reg in bits 0-4
        emitRaw32(0xF84107E0 | reg);
    }
    
    /// Standard function prologue (save LR and frame pointer)
    /// Uses the minimal form: just save x29,x30 without setting up frame pointer
    void emitPrologue() {
        // STP x29, x30, [sp, #-16]!  (0xa9bf7bfd)
        emitRaw32(0xA9BF7BFD);
    }
    
    /// Standard function epilogue (restore LR and frame pointer, return)
    void emitEpilogue() {
        // LDP x29, x30, [sp], #16  (0xa8c17bfd)
        emitRaw32(0xA8C17BFD);
        // RET (0xd65f03c0)
        emitRaw32(0xD65F03C0);
    }
    
    // ========== Stack Frame for Locals ==========
    // Use the real stack for locals. Much simpler than shadow stack.
    // Stack layout after prologue:
    //   sp+0:           local[0]
    //   sp+localBytes:  saved x29, x30
    
    /// Emit prologue with stack space for locals
    void emitPrologueWithLocals(uint localBytes) {
        // Align to 16 bytes
        uint frameSize = ((localBytes + 15) & ~15) + 16;  // +16 for x29,x30
        
        // SUB sp, sp, #frameSize
        emitRaw32(0xD10003FF | (frameSize << 10));
        // STP x29, x30, [sp, #localBytes]
        uint offset = frameSize - 16;
        emitRaw32(0xA9007BFD | ((offset / 8) << 15));
        // ADD x29, sp, #localBytes (set frame pointer)
        emitRaw32(0x910003FD | (offset << 10));
    }
    
    /// Emit epilogue that deallocates stack frame
    void emitEpilogueWithLocals(uint localBytes) {
        uint frameSize = ((localBytes + 15) & ~15) + 16;
        uint offset = frameSize - 16;
        
        // LDP x29, x30, [sp, #localBytes]
        emitRaw32(0xA9407BFD | ((offset / 8) << 15));
        // ADD sp, sp, #frameSize
        emitRaw32(0x910003FF | (frameSize << 10));
        // RET
        emitRaw32(0xD65F03C0);
    }
    
    /// Store x0 to local at offset (64-bit)
    void emitStoreLocal(uint offset) {
        // STR x0, [sp, #offset]
        uint imm12 = offset / 8;
        emitRaw32(0xF90003E0 | (imm12 << 10));
    }
    
    /// Load from local to x0 (64-bit)
    void emitLoadLocal(uint offset) {
        // LDR x0, [sp, #offset]
        uint imm12 = offset / 8;
        emitRaw32(0xF94003E0 | (imm12 << 10));
    }
    
    /// Store x0 to local at offset (32-bit)
    void emitStoreLocal32(uint offset) {
        // STR w0, [sp, #offset]
        uint imm12 = offset / 4;
        emitRaw32(0xB90003E0 | (imm12 << 10));
    }
    
    /// Store x1 to local at offset (32-bit) - for second parameter
    void emitStoreLocal32FromX1(uint offset) {
        // STR w1, [sp, #offset]
        uint imm12 = offset / 4;
        emitRaw32(0xB90003E1 | (imm12 << 10));
    }
    
    /// Store x2 to local at offset (32-bit) - for third parameter
    void emitStoreLocal32FromX2(uint offset) {
        // STR w2, [sp, #offset]
        uint imm12 = offset / 4;
        emitRaw32(0xB90003E2 | (imm12 << 10));
    }
    
    /// Store x3 to local at offset (32-bit) - for fourth parameter
    void emitStoreLocal32FromX3(uint offset) {
        // STR w3, [sp, #offset]
        uint imm12 = offset / 4;
        emitRaw32(0xB90003E3 | (imm12 << 10));
    }
    
    // Abstract aliases for parameter spilling
    alias emitStoreArg1ToLocal32 = emitStoreLocal32FromX1;
    alias emitStoreArg2ToLocal32 = emitStoreLocal32FromX2;
    alias emitStoreArg3ToLocal32 = emitStoreLocal32FromX3;
    
    /// Load from local to x0 (32-bit, zero-extended)
    void emitLoadLocal32(uint offset) {
        // LDR w0, [sp, #offset]
        uint imm12 = offset / 4;
        emitRaw32(0xB94003E0 | (imm12 << 10));
    }
    
    /// Increment 32-bit local in place: [fp + offset]++
    /// Result left in x0
    void emitIncLocal32(uint offset) {
        emitImm32(stencil_inc_local_i32, cast(int)offset);
    }
    
    // ========== Struct Support ==========
    
    /// Load stack pointer into x0: MOV x0, sp
    void emitLoadStackPointer() {
        // MOV x0, sp is actually ADD x0, sp, #0
        // ADD x0, sp, #0 = 0x910003E0
        emitRaw32(0x910003E0);
    }
    
    /// Load 32-bit value from pointer in x0 with offset: LDR w0, [x0, #offset]
    void emitLoadFromPointer(uint offset) {
        // LDR w0, [x0, #offset] where offset is scaled by 4
        uint imm12 = offset / 4;
        emitRaw32(0xB9400000 | (imm12 << 10));
    }
    
    /// Store 32-bit value from x1 to pointer in x0 with offset: STR w1, [x0, #offset]  
    void emitStoreToPointer(uint offset) {
        // STR w1, [x0, #offset] where offset is scaled by 4
        uint imm12 = offset / 4;
        emitRaw32(0xB9000001 | (imm12 << 10));
    }
    
    // ========== Finalization ==========
    
    /// Resolve all branch targets and make code executable
    bool finalize() {
        // Patch all unresolved branches
        foreach (ref br; unresolved) {
            // Find the target label
            Label* target;
            foreach (ref l; labels) {
                if (l.id == br.labelId) {
                    target = &l;
                    break;
                }
            }
            
            if (!target || !target.bound) {
                return false;  // Unbound label!
            }
            
            // Calculate relative offset (in bytes)
            int relOffset = cast(int)(target.offset) - cast(int)(br.offset);
            
            // Patch the instruction
            uint* instr = cast(uint*)(base + br.offset);
            
            final switch (br.kind) {
                case BranchKind.unconditional:
                    // B: imm26 = offset/4
                    int imm26 = relOffset / 4;
                    *instr = 0x14000000 | (imm26 & 0x03FFFFFF);
                    break;
                    
                case BranchKind.ifZero:
                    // CBZ: imm19 in bits 5-23, preserve register in bits 0-4
                    int imm19 = relOffset / 4;
                    *instr = (*instr & 0x1F) | 0x34000000 | ((imm19 & 0x7FFFF) << 5);
                    break;
                    
                case BranchKind.ifNonZero:
                    // CBNZ: imm19 in bits 5-23, preserve register in bits 0-4
                    int imm19_2 = relOffset / 4;
                    *instr = (*instr & 0x1F) | 0x35000000 | ((imm19_2 & 0x7FFFF) << 5);
                    break;
                    
                case BranchKind.call:
                    // BL: imm26 = offset/4
                    int imm26_call = relOffset / 4;
                    *instr = 0x94000000 | (imm26_call & 0x03FFFFFF);
                    break;
                    
                case BranchKind.conditional:
                    // B.cond: imm19 in bits 5-23, preserve condition in bits 0-3
                    int imm19_cond = relOffset / 4;
                    *instr = (*instr & 0xF) | 0x54000000 | ((imm19_cond & 0x7FFFF) << 5);
                    break;
            }
        }
        
        // Make executable
        mprotect(base, capacity, PROT_READ | PROT_EXEC);
        return true;
    }
    
    /// Get function pointer
    T getFunc(T)(size_t off = 0) {
        return cast(T)(base + off);
    }
    
    /// Free the buffer
    void free() {
        if (base) munmap(base, capacity);
    }
}

// Function pointer types
extern(C) {
    alias NullaryFn = long function();
    alias UnaryFn = long function(long);
    alias BinaryFn = long function(long, long);
}
// CTFE host function implementations (extern(C) for ARM64 ABI compatibility)
// All functions receive NativeCTFEContext* as first parameter
// Using _native_ prefix to avoid name collisions

/// CTFE allocator - bump allocates from the context's data section
/// Returns pointer to allocated memory, or 0 if out of space
private extern(C) long _native_ctfe_alloc(NativeCTFEContext* ctx, long size, long, long) nothrow {
    if (ctx is null || ctx.dataSection is null) return 0;
    
    auto ds = ctx.dataSection;
    
    // Align size to 8 bytes
    size_t alignedSize = (cast(size_t)size + 7) & ~cast(size_t)7;
    
    // Check if we have space
    if (ds.used + alignedSize > ds.capacity) {
        return 0;  // out of memory
    }
    
    // Bump allocate
    long ptr = cast(long)(ds.base + ds.used);
    ds.used += alignedSize;
    return ptr;
}

private extern(C) long _native_ctfe_write_i32(NativeCTFEContext* ctx, long val, long, long) nothrow {
    import std.stdio : write;
    try { write(cast(int)val); } catch (Exception) {}
    return 0;
}

private extern(C) long _native_ctfe_write_str(NativeCTFEContext* ctx, long ptr, long len, long) nothrow {
    import std.stdio : write;
    try {
        auto str = (cast(char*)ptr)[0 .. cast(size_t)len];
        write(str);
    } catch (Exception) {}
    return 0;
}

private extern(C) long _native_ctfe_write_bool(NativeCTFEContext* ctx, long val, long, long) nothrow {
    import std.stdio : write;
    try { write(val != 0 ? "true" : "false"); } catch (Exception) {}
    return 0;
}

private extern(C) long _native_ctfe_write_newline(NativeCTFEContext* ctx, long, long, long) nothrow {
    import std.stdio : writeln;
    try { writeln(); } catch (Exception) {}
    return 0;
}

private extern(C) long _native_ctfe_print_i32(NativeCTFEContext* ctx, long val, long, long) nothrow {
    import std.stdio : writeln;
    try { writeln("CTFE: ", cast(int)val); } catch (Exception) {}
    return 0;
}

/// Error location data passed to trap handler
struct ErrorLocData {
    ulong filePtr;
    uint fileLen;
    uint line;
    uint column;
    uint errorKind;
}

/// CTFE trap handler - called when a runtime error occurs
/// Uses longjmp to abort execution and return to setjmp in call()
/// Args: errorLocPtr (pointer to ErrorLocData struct with location + error kind)
private extern(C) long _native_ctfe_trap(NativeCTFEContext* ctx, long errorLocPtr, long, long) nothrow {
    import codegen.native.codegen_interface : longjmp;
    if (ctx is null) return -1;
    
    auto data = cast(ErrorLocData*)errorLocPtr;
    if (data !is null) {
        ctx.errorKind = cast(CTFEErrorKind)data.errorKind;
        ctx.setErrorLocation(
            cast(const(char)*)data.filePtr, data.fileLen,
            data.line, data.column
        );
    }
    
    longjmp(ctx.errorJump, 1);  // Non-local exit to call()
    
    // Never reached - longjmp doesn't return
    return -1;
}

/// Push call frame onto call stack (for error reporting)
/// We pack 5 values into 3 args using a struct in memory
/// Args: framePtr (pointer to CallFrameData struct)
struct CallFrameData {
    ulong namePtr;
    uint nameLen;
    ulong filePtr;
    uint fileLen;
    uint line;
}

private extern(C) long _native_ctfe_push_call(NativeCTFEContext* ctx, long framePtr, long, long) nothrow {
    if (ctx is null) return -1;
    auto data = cast(CallFrameData*)framePtr;
    if (data is null) return -1;
    ctx.pushCall(
        cast(const(char)*)data.namePtr, data.nameLen,
        cast(const(char)*)data.filePtr, data.fileLen,
        data.line
    );
    return 0;
}

/// Pop function name from call stack
private extern(C) long _native_ctfe_pop_call(NativeCTFEContext* ctx, long, long, long) nothrow {
    if (ctx is null) return -1;
    ctx.popCall();
    return 0;
}

/**
 * Create a HostFunctionTable pre-populated with CTFE intrinsics.
 */
HostFunctionTable createCTFEHostFunctions() {
    HostFunctionTable table;
    
    table.registerFunction("__ctfe_alloc", &_native_ctfe_alloc);
    table.registerFunction("__ctfe_write_i32", &_native_ctfe_write_i32);
    table.registerFunction("__ctfe_write_str", &_native_ctfe_write_str);
    table.registerFunction("__ctfe_write_bool", &_native_ctfe_write_bool);
    table.registerFunction("__ctfe_write_newline", &_native_ctfe_write_newline);
    table.registerFunction("__ctfe_print_i32", &_native_ctfe_print_i32);
    table.registerFunction("__ctfe_trap", &_native_ctfe_trap);
    table.registerFunction("__ctfe_push_call", &_native_ctfe_push_call);
    table.registerFunction("__ctfe_pop_call", &_native_ctfe_pop_call);
    
    return table;
}

// Unittest for HostFunctionTable - Milestone 87/90
unittest {
    import std.stdio : writeln;
    
    HostFunctionTable table;
    
    // Register a test function (new signature with context)
    extern(C) long testFunc(NativeCTFEContext* ctx, long a, long b, long) nothrow {
        return a + b;
    }
    
    size_t idx = table.registerFunction("test_add", &testFunc);
    assert(idx == 0, "First function should have index 0");
    assert(table.count == 1, "Should have 1 function");
    
    // Look up by name
    auto func = table.getFunction("test_add");
    assert(func !is null, "Should find registered function");
    assert(func(null, 10, 20, 0) == 30, "Function should work");
    
    // Look up index
    assert(table.getFunctionIndex("test_add") == 0);
    assert(table.getFunctionIndex("nonexistent") == -1);
    
    // Get slot address (for native code)
    ulong slotAddr = table.getFunctionSlotAddress("test_add");
    assert(slotAddr != 0, "Slot address should be non-zero");
    
    // Verify slot contains the function pointer
    auto slotPtr = cast(HostFunctionPtr*)slotAddr;
    assert(*slotPtr == &testFunc, "Slot should contain function pointer");
    
    // Test CTFE functions
    auto ctfeTable = createCTFEHostFunctions();
    assert(ctfeTable.count == 9, "Should have 9 CTFE functions");
    assert(ctfeTable.getFunction("__ctfe_write_i32") !is null);
    assert(ctfeTable.getFunction("__ctfe_write_str") !is null);
    assert(ctfeTable.getFunction("__ctfe_write_bool") !is null);
    assert(ctfeTable.getFunction("__ctfe_write_newline") !is null);
    assert(ctfeTable.getFunction("__ctfe_print_i32") !is null);
    
    writeln("✓ HostFunctionTable unittest passed");
}
