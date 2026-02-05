/**
 * ARM64 Native Code Generator
 * 
 * Implements INativeCodeGen for ARM64 (AArch64) architecture.
 * Uses the stencil table from arm64/stencil_table.d.
 */
module codegen.native.arm64.codegen;

import codegen.native.codegen_interface;
import codegen.native.stencil_catalog;
import codegen.native.arm64.stencil_table;
import core.sys.posix.sys.mman;
import core.stdc.string : memcpy;

version(OSX) {
    private enum MAP_ANONYMOUS = 0x1000;
    private enum MAP_JIT = 0x0800;
}

/**
 * ARM64 Native Code Generator
 * 
 * Implements the INativeCodeGen interface for ARM64 architecture.
 * 
 * ARM64 Register Mapping:
 *   result  = x0
 *   arg0    = x0
 *   arg1    = x1
 *   arg2    = x2
 *   arg3    = x3
 *   scratch = x9
 *   frame   = x29 (fp)
 *   link    = x30 (lr)
 */
class ARM64CodeGen : INativeCodeGen {
    
    private ubyte* _base;
    private size_t capacity;
    private size_t offset;
    
    // Branch management
    private Label[] labels;
    private UnresolvedBranch[] unresolved;
    private int nextLabelId;
    
    private struct UnresolvedBranch {
        uint offset;
        int labelId;
        BranchKind kind;
    }
    
    private enum BranchKind {
        unconditional,
        ifZero,
        ifNonZero,
        call,
    }
    
    /// Create a new ARM64 code generator
    static ARM64CodeGen create(size_t size) {
        void* mem = mmap(null, size,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT,
            -1, 0);
        
        if (mem == MAP_FAILED) return null;
        
        auto gen = new ARM64CodeGen();
        gen._base = cast(ubyte*)mem;
        gen.capacity = size;
        gen.offset = 0;
        gen.nextLabelId = 0;
        return gen;
    }
    
    // ===== Buffer Management =====
    
    override @property uint pos() { return cast(uint)offset; }
    override @property ubyte* base() { return _base; }
    
    override bool finalize() {
        // Resolve all branches
        foreach (ref branch; unresolved) {
            Label* target = null;
            foreach (ref l; labels) {
                if (l.id == branch.labelId) {
                    target = &l;
                    break;
                }
            }
            
            if (target is null || !target.bound) return false;
            
            int relOffset = cast(int)(target.offset - branch.offset);
            uint* instr = cast(uint*)(_base + branch.offset);
            
            final switch (branch.kind) {
                case BranchKind.unconditional:
                    // B: 0x14000000 | (offset/4 & 0x3FFFFFF)
                    *instr = 0x14000000 | ((relOffset / 4) & 0x3FFFFFF);
                    break;
                case BranchKind.ifZero:
                    // CBZ x0: 0xB4000000 | ((offset/4 & 0x7FFFF) << 5)
                    *instr = 0xB4000000 | (((relOffset / 4) & 0x7FFFF) << 5);
                    break;
                case BranchKind.ifNonZero:
                    // CBNZ x0: 0xB5000000 | ((offset/4 & 0x7FFFF) << 5)
                    *instr = 0xB5000000 | (((relOffset / 4) & 0x7FFFF) << 5);
                    break;
                case BranchKind.call:
                    // BL: 0x94000000 | (offset/4 & 0x3FFFFFF)
                    *instr = 0x94000000 | ((relOffset / 4) & 0x3FFFFFF);
                    break;
            }
        }
        
        // Make executable
        return mprotect(_base, capacity, PROT_READ | PROT_EXEC) == 0;
    }
    
    override void free() {
        if (_base !is null) {
            munmap(_base, capacity);
            _base = null;
        }
    }
    
    // ===== Internal Helpers =====
    
    private void emitBytes(const(ubyte)[] bytes) {
        if (offset + bytes.length > capacity) return;
        memcpy(_base + offset, bytes.ptr, bytes.length);
        offset += bytes.length;
    }
    
    private void emitRaw32(uint value) {
        if (offset + 4 > capacity) return;
        *cast(uint*)(_base + offset) = value;
        offset += 4;
    }
    
    private void emitStencilInternal(const ref Stencil s) {
        emitBytes(s.code);
    }
    
    private void patchImm16(void* addr, int holeOffset, ushort value) {
        uint* instr = cast(uint*)(cast(ubyte*)addr + holeOffset);
        *instr = (*instr & 0xFFE0001F) | (cast(uint)value << 5);
    }
    
    // ===== Stencil Emission =====
    
    override void* emitStencil(string name) {
        auto stencil = getStencil(name);
        if (stencil is null) return null;
        void* addr = _base + offset;
        emitStencilInternal(*stencil);
        return addr;
    }
    
    override void* emitStencilImm32(string name, int value) {
        auto stencil = getStencil(name);
        if (stencil is null) return null;
        
        void* addr = _base + offset;
        emitStencilInternal(*stencil);
        
        foreach (ref hole; stencil.holes) {
            switch (hole.kind) {
                case HoleKind.imm16_0:
                    patchImm16(addr, hole.offset, cast(ushort)(value & 0xFFFF));
                    break;
                case HoleKind.imm16_1:
                    patchImm16(addr, hole.offset, cast(ushort)((value >> 16) & 0xFFFF));
                    break;
                default:
                    break;
            }
        }
        return addr;
    }
    
    override void* emitStencilImm64(string name, ulong value) {
        auto stencil = getStencil(name);
        if (stencil is null) return null;
        
        void* addr = _base + offset;
        emitStencilInternal(*stencil);
        
        foreach (ref hole; stencil.holes) {
            switch (hole.kind) {
                case HoleKind.imm16_0:
                    patchImm16(addr, hole.offset, cast(ushort)(value & 0xFFFF));
                    break;
                case HoleKind.imm16_1:
                    patchImm16(addr, hole.offset, cast(ushort)((value >> 16) & 0xFFFF));
                    break;
                case HoleKind.imm16_2:
                    patchImm16(addr, hole.offset, cast(ushort)((value >> 32) & 0xFFFF));
                    break;
                case HoleKind.imm16_3:
                    patchImm16(addr, hole.offset, cast(ushort)((value >> 48) & 0xFFFF));
                    break;
                default:
                    break;
            }
        }
        return addr;
    }
    
    // ===== Arithmetic =====
    
    override void emitAdd() { emitStencil("add_i32"); }
    override void emitSub() { emitStencil("sub_i32"); }
    override void emitMul() { emitStencil("mul_i32"); }
    override void emitDiv() { emitStencil("div_i32"); }
    override void emitMod() { emitStencil("mod_i32"); }
    
    // ===== Bitwise =====
    
    override void emitAnd() { emitStencil("and_i32"); }
    override void emitOr() { emitStencil("or_i32"); }
    override void emitXor() { emitStencil("xor_i32"); }
    override void emitShl() { emitStencil("shl_i32"); }
    override void emitShr() { emitStencil("shr_i32"); }
    
    // ===== Comparison =====
    
    override void emitEq() { emitStencil("eq_i32"); }
    override void emitNe() { emitStencil("ne_i32"); }
    override void emitLt() { emitStencil("lt_i32"); }
    override void emitLe() { emitStencil("le_i32"); }
    override void emitGt() { emitStencil("gt_i32"); }
    override void emitGe() { emitStencil("ge_i32"); }
    
    // ===== Immediate Loading =====
    
    override void emitLoadImm(int value) {
        emitStencilImm32("load_imm32", value);
    }
    
    override void emitLoadImm64(ulong value) {
        emitStencilImm64("load_imm64", value);
    }
    
    override void emitLoadImm64ToScratch(ulong value) {
        emitStencilImm64("load_imm64_to_scratch", value);
    }
    
    // ===== Register Moves =====
    
    override void emitMoveResultToArg1() { emitStencil("move_result_to_arg1"); }
    override void emitMoveResultToArg2() { emitStencil("move_result_to_arg2"); }
    override void emitMoveResultToArg3() { emitStencil("move_result_to_arg3"); }
    override void emitMoveResultToScratch() { emitStencil("move_result_to_scratch"); }
    override void emitMoveScratchToResult() { emitStencil("move_scratch_to_result"); }
    override void emitMoveResultToScratch2() { emitStencil("move_result_to_scratch2"); }
    override void emitMoveScratch2ToResult() { emitStencil("move_scratch2_to_result"); }
    override void emitMoveArg1ToResult() { emitStencil("move_arg1_to_result"); }
    override void emitMoveArg2ToArg1() { emitStencil("move_arg2_to_arg1"); }
    
    // ===== Local Variable Access =====
    
    override void emitLoadLocal32(uint off) {
        emitStencilImm32("load_local_i32", cast(int)off);
    }
    
    override void emitStoreLocal32(uint off) {
        emitStencilImm32("store_local_i32", cast(int)off);
    }
    
    override void emitStoreArg1ToLocal32(uint off) {
        emitStencilImm32("store_arg1_to_local_i32", cast(int)off);
    }
    
    override void emitStoreArg2ToLocal32(uint off) {
        emitStencilImm32("store_arg2_to_local_i32", cast(int)off);
    }
    
    override void emitStoreArg3ToLocal32(uint off) {
        emitStencilImm32("store_arg3_to_local_i32", cast(int)off);
    }
    
    override void emitLoadLocal64(uint off) {
        emitStencilImm32("load_local_i64", cast(int)off);
    }
    
    override void emitStoreLocal64(uint off) {
        emitStencilImm32("store_local_i64", cast(int)off);
    }
    
    // ===== Memory Access =====
    
    override void emitLoadFromPointer32(uint off) {
        emitStencilImm32("load_i32", cast(int)off);
    }
    
    override void emitStoreToPointer32(uint off) {
        emitStencilImm32("store_i32", cast(int)off);
    }
    
    // ===== Stack Frame =====
    
    override void emitPrologue() {
        emitStencil("prologue");
    }
    
    override void emitPrologueWithLocals(uint size) {
        // Emit prologue stencil and patch the stack size
        auto stencil = getStencil("prologue_with_locals");
        if (stencil is null) return;
        
        void* addr = _base + offset;
        emitStencilInternal(*stencil);
        
        // Patch the SUB sp, sp, #size instruction
        // The immediate is in bits 10-21 (12-bit immediate)
        foreach (ref hole; stencil.holes) {
            if (hole.kind == HoleKind.frame_offset) {
                uint* instr = cast(uint*)(cast(ubyte*)addr + hole.offset);
                *instr = (*instr & 0xFFC003FF) | ((size & 0xFFF) << 10);
            }
        }
    }
    
    override void emitEpilogue() {
        emitStencil("epilogue");
    }
    
    override void emitEpilogueWithLocals(uint size) {
        auto stencil = getStencil("epilogue_with_locals");
        if (stencil is null) return;
        
        void* addr = _base + offset;
        emitStencilInternal(*stencil);
        
        foreach (ref hole; stencil.holes) {
            if (hole.kind == HoleKind.frame_offset) {
                uint* instr = cast(uint*)(cast(ubyte*)addr + hole.offset);
                *instr = (*instr & 0xFFC003FF) | ((size & 0xFFF) << 10);
            }
        }
    }
    
    override void emitLoadStackPointer() {
        emitStencil("get_frame_pointer");
    }
    
    // ===== Control Flow =====
    
    override Label newLabel() {
        auto label = Label(nextLabelId++, false, 0);
        labels ~= label;
        return label;
    }
    
    override void bindLabel(ref Label label) {
        label.bound = true;
        label.offset = pos;
        foreach (ref l; labels) {
            if (l.id == label.id) {
                l.bound = true;
                l.offset = pos;
                break;
            }
        }
    }
    
    override void emitBranch(Label target) {
        uint branchOffset = pos;
        emitRaw32(0x14000000);  // B placeholder
        unresolved ~= UnresolvedBranch(branchOffset, target.id, BranchKind.unconditional);
    }
    
    override void emitBranchIfZero(Label target) {
        uint branchOffset = pos;
        emitRaw32(0xB4000000);  // CBZ x0 placeholder
        unresolved ~= UnresolvedBranch(branchOffset, target.id, BranchKind.ifZero);
    }
    
    override void emitBranchIfNonZero(Label target) {
        uint branchOffset = pos;
        emitRaw32(0xB5000000);  // CBNZ x0 placeholder
        unresolved ~= UnresolvedBranch(branchOffset, target.id, BranchKind.ifNonZero);
    }
    
    override void emitCall(Label target) {
        uint callOffset = pos;
        emitRaw32(0x94000000);  // BL placeholder
        unresolved ~= UnresolvedBranch(callOffset, target.id, BranchKind.call);
    }
    
    override void emitRet() {
        emitStencil("return_val");
    }
    
    // ===== Indirect Calls =====
    
    override void emitLoadPtrFromScratch() {
        emitStencil("load_ptr_indirect");
    }
    
    override void emitCallIndirect() {
        emitStencil("call_indirect");
    }
    
    override void emitIndirectCall(ulong slotAddress) {
        emitLoadImm64ToScratch(slotAddress);
        emitLoadPtrFromScratch();
        emitCallIndirect();
    }
    
    // ===== Architecture Info =====
    
    override string architecture() { return "arm64"; }
}
