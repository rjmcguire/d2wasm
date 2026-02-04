/**
 * Native Code Generator using Copy-and-Patch
 * 
 * Provides a higher-level interface for emitting native ARM64 code
 * using pre-compiled stencils with runtime patching.
 * 
 * Source: ~/projects/copy-patch-arm64/
 */
module codegen.native.arm64_codegen;

import codegen.native.stencil_table;
import core.sys.posix.sys.mman;
import core.stdc.string : memcpy;

version(OSX) {
    enum MAP_ANONYMOUS = 0x1000;
    enum MAP_JIT = 0x0800;
}

/// Label for branch targets
struct Label {
    int id;
    bool bound;      // Has the label been placed?
    uint offset;     // Offset in code buffer (valid if bound)
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
            final switch (hole.kind) {
                case HoleKind.imm16_lo:
                case HoleKind.imm16_lo_2:
                    *instr = (*instr & 0xFFE0001F) | ((value & 0xFFFF) << 5);
                    break;
                case HoleKind.imm16_hi:
                case HoleKind.imm16_hi_2:
                    *instr = (*instr & 0xFFE0001F) | (((value >> 16) & 0xFFFF) << 5);
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
    
    /// Load from local to x0 (32-bit, zero-extended)
    void emitLoadLocal32(uint offset) {
        // LDR w0, [sp, #offset]
        uint imm12 = offset / 4;
        emitRaw32(0xB94003E0 | (imm12 << 10));
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
                    // CBZ: imm19 in bits 5-23
                    int imm19 = relOffset / 4;
                    *instr = 0x34000000 | ((imm19 & 0x7FFFF) << 5);
                    break;
                    
                case BranchKind.ifNonZero:
                    // CBNZ: imm19 in bits 5-23
                    int imm19_2 = relOffset / 4;
                    *instr = 0x35000000 | ((imm19_2 & 0x7FFFF) << 5);
                    break;
                    
                case BranchKind.call:
                    // BL: imm26 = offset/4
                    int imm26_call = relOffset / 4;
                    *instr = 0x94000000 | (imm26_call & 0x03FFFFFF);
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
