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
    /// contextSlotAddress = address of the CTFEContext* in memory
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

// ============================================================================
// Native Data Section - Milestone 85
// ============================================================================

/**
 * Separate memory region for CTFE data storage.
 * 
 * This provides a mmap'd memory block for storing data that native code
 * needs to access (e.g., file contents from import(), string literals).
 * 
 * Benefits:
 * - Memory isolation from generated code
 * - Can be made read-only after initialization
 * - Stable pointers that persist for the lifetime of compilation
 */
struct NativeDataSection {
    ubyte* base;
    size_t capacity;
    size_t used;
    
    /// Allocate a data section with the given capacity
    static NativeDataSection alloc(size_t size) {
        // Use mmap for memory that's separate from code
        // READ+WRITE initially, could be made READ-only later
        void* mem = mmap(null, size,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS,
            -1, 0);
        
        if (mem == MAP_FAILED) {
            return NativeDataSection.init;
        }
        
        return NativeDataSection(cast(ubyte*)mem, size, 0);
    }
    
    /// Add data to the section, returns pointer to the data
    /// Returns null if out of space
    ubyte* addData(const(ubyte)[] data) {
        if (used + data.length > capacity) {
            return null;  // Out of space
        }
        
        ubyte* ptr = base + used;
        memcpy(ptr, data.ptr, data.length);
        used += data.length;
        
        // Align to 8 bytes for next allocation
        used = (used + 7) & ~7;
        
        return ptr;
    }
    
    /// Add a string (convenience method)
    ubyte* addString(string s) {
        return addData(cast(const(ubyte)[])s);
    }
    
    /// Get current usage
    @property size_t bytesUsed() { return used; }
    
    /// Get remaining capacity
    @property size_t bytesRemaining() { return capacity - used; }
    
    /// Make the section read-only (call after all data is added)
    bool makeReadOnly() {
        if (base is null) return false;
        return mprotect(base, capacity, PROT_READ) == 0;
    }
    
    /// Free the data section
    void free() {
        if (base !is null) {
            munmap(base, capacity);
            base = null;
            capacity = 0;
            used = 0;
        }
    }
}

// Unittest for NativeDataSection - Milestone 85
unittest {
    import std.stdio : writeln;
    
    // Allocate a small data section
    auto dataSection = NativeDataSection.alloc(4096);
    scope(exit) dataSection.free();
    
    assert(dataSection.base !is null, "Failed to allocate data section");
    assert(dataSection.capacity == 4096);
    assert(dataSection.bytesUsed == 0);
    
    // Add some data
    ubyte[5] testData = [0x48, 0x65, 0x6c, 0x6c, 0x6f];  // "Hello"
    ubyte* ptr1 = dataSection.addData(testData[]);
    
    assert(ptr1 !is null, "Failed to add data");
    assert(ptr1 == dataSection.base, "First allocation should be at base");
    assert(ptr1[0..5] == testData[], "Data should match");
    
    // Add more data
    ubyte[3] moreData = [0x01, 0x02, 0x03];
    ubyte* ptr2 = dataSection.addData(moreData[]);
    
    assert(ptr2 !is null, "Failed to add second data");
    assert(ptr2 > ptr1, "Second allocation should be after first");
    assert(ptr2[0..3] == moreData[], "Second data should match");
    
    // Original data should still be valid
    assert(ptr1[0..5] == testData[], "First data should still be valid");
    
    // Test string convenience method
    ubyte* strPtr = dataSection.addString("test");
    assert(strPtr !is null);
    assert(cast(char[])strPtr[0..4] == "test");
    
    writeln("✓ NativeDataSection unittest passed");
}

// ============================================================================
// Host Function Table - Milestone 87
// ============================================================================

/**
 * Function pointer type for host functions callable from native code.
 * 
 * Uses extern(C) calling convention for compatibility with ARM64 ABI:
 * - Arguments passed in x0-x7
 * - Return value in x0
 * - All parameters are long (64-bit) for simplicity
 */
/// Host function signature: context in first param, then up to 3 args
alias HostFunctionPtr = extern(C) long function(CTFEContext*, long, long, long) nothrow;

/**
 * CTFE Execution Context - passed to all host functions.
 * 
 * This provides host functions with access to the execution environment
 * without requiring global state. All host functions receive this as
 * their first parameter (in x0).
 */
struct CTFEContext {
    NativeDataSection* dataSection;
    // Future: add other execution state as needed
}

/**
 * Registry of host functions that native CTFE code can call.
 * 
 * Native code will:
 * 1. Look up function by name to get the table index
 * 2. Load the function pointer from the table (and context)
 * 3. Load execution context into x0
 * 4. Call function via BLR instruction
 * 
 * This struct holds both the mapping and the actual pointer table
 * that generated code can index into. Also stores the execution context
 * pointer that gets passed to all host functions.
 */
struct HostFunctionTable {
    /// Map from function name to table index
    private size_t[string] nameToIndex;
    
    /// Array of function pointers (stable addresses for native code)
    private HostFunctionPtr[] functions;
    
    /// Array of function names (for debugging)
    private string[] names;
    
    /// Execution context pointer - passed to all host functions in x0
    private CTFEContext* context;
    
    /// Register a host function, returns its index
    size_t registerFunction(string name, HostFunctionPtr func) {
        if (auto existingIdx = name in nameToIndex) {
            // Already registered - update the pointer
            functions[*existingIdx] = func;
            return *existingIdx;
        }
        
        size_t idx = functions.length;
        functions ~= func;
        names ~= name;
        nameToIndex[name] = idx;
        return idx;
    }
    
    /// Look up a function by name, returns null if not found
    HostFunctionPtr getFunction(string name) {
        if (auto idx = name in nameToIndex) {
            return functions[*idx];
        }
        return null;
    }
    
    /// Get the index of a function by name, returns -1 if not found
    long getFunctionIndex(string name) {
        if (auto idx = name in nameToIndex) {
            return cast(long)*idx;
        }
        return -1;
    }
    
    /// Get the address of a function pointer in the table (for native code to load)
    /// This returns the address of the slot, not the function itself
    ulong getFunctionSlotAddress(string name) {
        if (auto idx = name in nameToIndex) {
            // Return address of the function pointer in our array
            return cast(ulong)&functions[*idx];
        }
        return 0;
    }
    
    /// Get the address of a function pointer by index
    ulong getFunctionSlotAddressByIndex(size_t idx) {
        if (idx < functions.length) {
            return cast(ulong)&functions[idx];
        }
        return 0;
    }
    
    /// Number of registered functions
    @property size_t count() { return functions.length; }
    
    /// Get all registered function names (for debugging)
    @property const(string)[] registeredNames() { return names; }
    
    /// Set the execution context (call before executing native code)
    void setContext(CTFEContext* ctx) {
        context = ctx;
    }
    
    /// Get the address of the context pointer slot
    /// Generated code loads from this address to get the context
    ulong getContextSlotAddress() {
        return cast(ulong)&context;
    }
}

// CTFE host function implementations (extern(C) for ARM64 ABI compatibility)
// All functions receive CTFEContext* as first parameter
// Using _native_ prefix to avoid name collisions

/// CTFE allocator - bump allocates from the context's data section
/// Returns pointer to allocated memory, or 0 if out of space
private extern(C) long _native_ctfe_alloc(CTFEContext* ctx, long size, long, long) nothrow {
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

private extern(C) long _native_ctfe_write_i32(CTFEContext* ctx, long val, long, long) nothrow {
    import std.stdio : write;
    try { write(cast(int)val); } catch (Exception) {}
    return 0;
}

private extern(C) long _native_ctfe_write_str(CTFEContext* ctx, long ptr, long len, long) nothrow {
    import std.stdio : write;
    try {
        auto str = (cast(char*)ptr)[0 .. cast(size_t)len];
        write(str);
    } catch (Exception) {}
    return 0;
}

private extern(C) long _native_ctfe_write_bool(CTFEContext* ctx, long val, long, long) nothrow {
    import std.stdio : write;
    try { write(val != 0 ? "true" : "false"); } catch (Exception) {}
    return 0;
}

private extern(C) long _native_ctfe_write_newline(CTFEContext* ctx, long, long, long) nothrow {
    import std.stdio : writeln;
    try { writeln(); } catch (Exception) {}
    return 0;
}

private extern(C) long _native_ctfe_print_i32(CTFEContext* ctx, long val, long, long) nothrow {
    import std.stdio : writeln;
    try { writeln("CTFE: ", cast(int)val); } catch (Exception) {}
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
    
    return table;
}

// Unittest for HostFunctionTable - Milestone 87/90
unittest {
    import std.stdio : writeln;
    
    HostFunctionTable table;
    
    // Register a test function (new signature with context)
    extern(C) long testFunc(CTFEContext* ctx, long a, long b, long) nothrow {
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
    assert(ctfeTable.count == 6, "Should have 6 CTFE functions");
    assert(ctfeTable.getFunction("__ctfe_write_i32") !is null);
    assert(ctfeTable.getFunction("__ctfe_write_str") !is null);
    assert(ctfeTable.getFunction("__ctfe_write_bool") !is null);
    assert(ctfeTable.getFunction("__ctfe_write_newline") !is null);
    assert(ctfeTable.getFunction("__ctfe_print_i32") !is null);
    
    writeln("✓ HostFunctionTable unittest passed");
}
