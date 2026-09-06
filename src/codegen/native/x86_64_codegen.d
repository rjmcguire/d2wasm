/**
 * Native Code Generator for x86-64 (copy-and-patch)
 *
 * Same NativeCodeGen API as the ARM64 backend so NativeCompiledFunction
 * can lower without architecture-specific branches.
 *
 * Virtual ARM64 register names in method names map to:
 *   x0=rax  x1=rcx  x2=rdx  x3=rsi  x4=r8  x5=r9  x6=r10  x7=rdi
 *   x8=r12  x9=r11  x10=r13
 *
 * Function entry shuffles SysV (rdi,rsi,rdx,rcx,r8,r9) into that mapping.
 * Locals are RBP-relative so CALL (which pushes a return address) is safe.
 */
module codegen.native.x86_64_codegen;

import codegen.native.stencil_catalog;
import codegen.native.x86_64.stencil_table;
import codegen.native.codegen_interface : Label, NativeDataSection, NativeCTFEContext,
    HostFunctionPtr, HostFunctionTable, CTFEErrorKind, ctfeErrorMessage, longjmp,
    MAP_ANONYMOUS, MAP_JIT;
import core.sys.posix.sys.mman;
import core.stdc.string : memcpy;
import core.stdc.stdlib : malloc, free;

public import codegen.native.arm64_codegen : CallFrameData, ErrorLocData, createCTFEHostFunctions;

enum : ubyte {
    RAX = 0, RCX = 1, RDX = 2, RBX = 3, RSP = 4, RBP = 5, RSI = 6, RDI = 7,
    R8 = 8, R9 = 9, R10 = 10, R11 = 11, R12 = 12, R13 = 13, R14 = 14, R15 = 15,
}

enum ubyte XR0 = RAX;
enum ubyte XR1 = RCX;
enum ubyte XR2 = RDX;
enum ubyte XR3 = RSI;
enum ubyte XR4 = R8;
enum ubyte XR5 = R9;
enum ubyte XR6 = R10;
enum ubyte XR7 = RDI;
enum ubyte XR8 = R12;
enum ubyte XR9 = R11;
enum ubyte XR10 = R13;

/// ARM xN -> x86 encoding (unmapped registers become R14)
private immutable ubyte[11] xReg = [
    XR0, XR1, XR2, XR3, XR4, XR5, XR6, XR7, XR8, XR9, XR10
];

struct UnresolvedBranch {
    uint offset;
    int labelId;
    BranchKind kind;
}

enum BranchKind {
    unconditional,  // jmp rel32 (5 bytes, disp at +1)
    ifZero,         // jz  rel32 (6 bytes, disp at +2)
    ifNonZero,      // jnz rel32
    call,           // call rel32 (5 bytes, disp at +1)
    conditional,    // jge rel32 (6 bytes)
    adr,            // lea rax, [rip+disp32] (7 bytes, disp at +3)
}

struct NativeCodeGen {
    ubyte* base;
    size_t capacity;
    size_t offset;

    Label[] labels;
    UnresolvedBranch[] unresolved;
    int nextLabelId;

    bool relocatable;
    bool finalized;

    /// Bytes from RBP down to SP after prologue (saved r12/r13 + locals)
    uint frameSize;
    uint localAlloc;  // extra SUB RSP amount (aligned localBytes)

    static NativeCodeGen alloc(size_t initialSize = 64 * 1024) {
        auto mem = cast(ubyte*)malloc(initialSize);
        if (mem is null) return NativeCodeGen.init;
        return NativeCodeGen(mem, initialSize, 0);
    }

    static NativeCodeGen allocRelocatable(size_t initialSize = 64 * 1024) {
        auto mem = cast(ubyte*)malloc(initialSize);
        if (mem is null) return NativeCodeGen.init;
        auto gen = NativeCodeGen(mem, initialSize, 0);
        gen.relocatable = true;
        return gen;
    }

    private bool ensureCapacity(size_t needed) {
        if (offset + needed <= capacity) return true;
        import core.stdc.stdlib : realloc;
        size_t newCap = capacity;
        while (newCap < offset + needed) newCap *= 2;
        auto newBuf = cast(ubyte*)realloc(base, newCap);
        if (newBuf is null) return false;
        base = newBuf;
        capacity = newCap;
        return true;
    }

    @property uint pos() { return cast(uint)offset; }

    // ========== Byte emission ==========

    void emitU8(ubyte b) {
        if (!ensureCapacity(1)) return;
        base[offset] = b;
        offset += 1;
    }

    void emitU32(uint v) {
        if (!ensureCapacity(4)) return;
        *cast(uint*)(base + offset) = v;
        offset += 4;
    }

    void emitU64(ulong v) {
        if (!ensureCapacity(8)) return;
        *cast(ulong*)(base + offset) = v;
        offset += 8;
    }

    void emitRaw32(uint instr) {
        emitU32(instr);
    }

    void emitRawBytes(const ubyte[] bytes) {
        emitBytes(bytes);
    }

    void* emitBytes(const(ubyte)[] bytes) {
        if (!ensureCapacity(bytes.length)) return null;
        void* addr = base + offset;
        memcpy(addr, bytes.ptr, bytes.length);
        offset += bytes.length;
        return addr;
    }

    void* emit(const ref Stencil s) {
        return emitBytes(s.code);
    }

    void* emitImm32(const ref Stencil s, int value) {
        void* addr = emit(s);
        if (!addr) return null;
        auto p = cast(ubyte*)addr;
        foreach (ref hole; s.holes) {
            switch (hole.kind) {
                case HoleKind.imm32:
                    *cast(int*)(p + hole.offset) = value;
                    break;
                case HoleKind.imm16_0:
                    *cast(ushort*)(p + hole.offset) = cast(ushort)(value & 0xFFFF);
                    break;
                case HoleKind.imm16_1:
                    *cast(ushort*)(p + hole.offset) = cast(ushort)((value >> 16) & 0xFFFF);
                    break;
                default:
                    break;
            }
        }
        return addr;
    }

    // ========== REX / ModRM helpers ==========

    /// MOV dst, src  (64-bit)
    void emitMovRR(ubyte dst, ubyte src) {
        ubyte rex = 0x48;
        if (src & 8) rex |= 0x04;
        if (dst & 8) rex |= 0x01;
        emitU8(rex);
        emitU8(0x89);
        emitU8(cast(ubyte)(0xC0 | ((src & 7) << 3) | (dst & 7)));
    }

    /// LEA dst, [rbp + disp32]
    void emitLeaRbp(ubyte dst, int disp) {
        ubyte rex = 0x48;
        if (dst & 8) rex |= 0x04;
        emitU8(rex);
        emitU8(0x8D);
        emitU8(cast(ubyte)(0x85 | ((dst & 7) << 3))); // mod=10 rm=rbp
        emitU32(cast(uint)disp);
    }

    /// MOV r32, [rbp+disp]  (dst is 64-reg number; 32-bit load zero-extends)
    void emitLoad32Rbp(ubyte dst, int disp) {
        ubyte rex = 0x40;
        bool needRex = (dst & 8) != 0;
        if (needRex) {
            rex |= 0x04;
            emitU8(rex);
        }
        emitU8(0x8B);
        emitU8(cast(ubyte)(0x85 | ((dst & 7) << 3)));
        emitU32(cast(uint)disp);
    }

    /// MOV r64, [rbp+disp]
    void emitLoad64Rbp(ubyte dst, int disp) {
        ubyte rex = 0x48;
        if (dst & 8) rex |= 0x04;
        emitU8(rex);
        emitU8(0x8B);
        emitU8(cast(ubyte)(0x85 | ((dst & 7) << 3)));
        emitU32(cast(uint)disp);
    }

    /// MOV [rbp+disp], r32
    void emitStore32Rbp(ubyte src, int disp) {
        if (src & 8) emitU8(0x44);
        emitU8(0x89);
        emitU8(cast(ubyte)(0x85 | ((src & 7) << 3)));
        emitU32(cast(uint)disp);
    }

    /// MOV [rbp+disp], r64
    void emitStore64Rbp(ubyte src, int disp) {
        ubyte rex = 0x48;
        if (src & 8) rex |= 0x04;
        emitU8(rex);
        emitU8(0x89);
        emitU8(cast(ubyte)(0x85 | ((src & 7) << 3)));
        emitU32(cast(uint)disp);
    }

    int localDisp(size_t off) {
        return cast(int)off - cast(int)frameSize;
    }

    // ========== Stencil arithmetic (same as ARM wrappers) ==========

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
    void emitRet() { emitU8(0xC3); }

    void emitLoadImm64(ulong value) {
        emitU8(0x48); emitU8(0xB8); emitU64(value);  // movabs rax, imm64
    }

    void emitLoadImm64ToX9(ulong value) {
        emitU8(0x49); emitU8(0xBB); emitU64(value);  // movabs r11, imm64
    }

    void emitLoadFromX9() {
        emitU8(0x4D); emitU8(0x8B); emitU8(0x1B);  // mov r11, [r11]
    }

    void emitLoadFromX9Offset(size_t off) {
        // mov eax, [r11 + off]
        emitU8(0x41); emitU8(0x8B); emitU8(0x83); emitU32(cast(uint)off);
    }

    void emitMoveX0ToX9() { emitMovRR(XR9, XR0); }
    void emitMoveX1ToX9() { emitMovRR(XR9, XR1); }
    void emitMoveX2ToX9() { emitMovRR(XR9, XR2); }
    void emitMoveX3ToX9() { emitMovRR(XR9, XR3); }
    void emitMoveX9ToX0() { emitMovRR(XR0, XR9); }
    void emitMoveX9ToX1() { emitMovRR(XR1, XR9); }

    void emitStackAddress(size_t off) {
        emitLeaRbp(XR0, localDisp(off));
    }

    /// SysV integer argument registers (rdi, rsi, rdx, rcx, r8, r9).
    int cAbiIntArgRegs() { return 6; }

    /// Locals/temps are RBP-relative, so SUB RSP for stack args does not move them.
    bool tempsUseFramePointer() { return true; }

    void emitCallIndirectX9() {
        emitU8(0x41); emitU8(0xFF); emitU8(0xD3);  // call r11
    }

    /// Virtual ARM-like args (rax,rcx,rdx,rsi,r8,r9) → SysV (rdi,rsi,rdx,rcx,r8,r9).
    /// Clobbers r11.
    void emitShuffleVirtualToCAbi() {
        emitMovRR(R11, RSI);  // save x3
        emitMovRR(RDI, RAX);  // SysV arg0
        emitMovRR(RSI, RCX);  // SysV arg1
        emitMovRR(RCX, R11);  // SysV arg3 (rdx is already arg2)
    }

    /// Shuffle to SysV then call through r11. Saves the callee in r14.
    void emitCallIndirectX9CAbi() {
        emitMovRR(R14, R11);
        emitShuffleVirtualToCAbi();
        emitU8(0x41); emitU8(0xFF); emitU8(0xD6);  // call r14
    }

    void emitAddX9X0LSL3() {
        // r11 += rax * 8  →  lea r11, [r11 + rax*8]
        // REX.W+R+B (r11 dest, r11 base): 4D 8D 1C C3
        // SIB: scale=8 (11), index=rax (000), base=r11 (011) wait
        // lea r11, [r11 + rax*8]
        // REX: W=1 R=1 (r11) X=0 (rax) B=1 (r11) = 4D
        // 8D
        // ModRM: 00 011 100 = 1C (mod=00, reg=r11, rm=SIB)
        // SIB: 11 000 011 = C3 (scale=8, index=rax, base=r11)
        emitU8(0x4D); emitU8(0x8D); emitU8(0x1C); emitU8(0xC3);
    }

    void emitIndirectCall(ulong slotAddress) {
        emitLoadImm64ToX9(slotAddress);
        emitLoadFromX9();
        emitCallIndirectX9CAbi();
    }

    /// Host call: SysV rdi=ctx, rsi=arg0, rdx=arg1, rcx=arg2
    /// Virtual incoming: rax=arg0, rcx=arg1, rdx=arg2
    void emitHostCall(ulong funcSlotAddress, ulong contextSlotAddress) {
        emitMovRR(RSI, RAX);          // rsi = arg0
        emitMovRR(R11, RCX);          // save arg1
        emitMovRR(RCX, RDX);          // rcx = arg2
        emitMovRR(RDX, R11);          // rdx = arg1
        emitLoadImm64ToX9(contextSlotAddress);
        emitU8(0x49); emitU8(0x8B); emitU8(0x3B);  // mov rdi, [r11]
        emitLoadImm64ToX9(funcSlotAddress);
        emitLoadFromX9();
        emitCallIndirectX9();
    }

    // ========== Labels / branches ==========

    Label newLabel() {
        auto label = Label(nextLabelId++, false, 0);
        labels ~= label;
        return label;
    }

    void bindLabel(ref Label label) {
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

    void emitBranch(Label target) {
        uint off = pos;
        emitU8(0xE9); emitU32(0);
        unresolved ~= UnresolvedBranch(off, target.id, BranchKind.unconditional);
    }

    void emitBranchIfZero(Label target) {
        emitU8(0x85); emitU8(0xC0);  // test eax, eax
        uint off = pos;
        emitU8(0x0F); emitU8(0x84); emitU32(0);  // jz
        unresolved ~= UnresolvedBranch(off, target.id, BranchKind.ifZero);
    }

    void emitBranchIfNonZero(Label target) {
        emitU8(0x85); emitU8(0xC0);
        uint off = pos;
        emitU8(0x0F); emitU8(0x85); emitU32(0);  // jnz
        unresolved ~= UnresolvedBranch(off, target.id, BranchKind.ifNonZero);
    }

    void emitBranchIfZeroX1(Label target) {
        emitU8(0x85); emitU8(0xC9);  // test ecx, ecx
        uint off = pos;
        emitU8(0x0F); emitU8(0x84); emitU32(0);
        unresolved ~= UnresolvedBranch(off, target.id, BranchKind.ifZero);
    }

    void emitBranchIfGE(Label target) {
        uint off = pos;
        emitU8(0x0F); emitU8(0x8D); emitU32(0);  // jge
        unresolved ~= UnresolvedBranch(off, target.id, BranchKind.conditional);
    }

    /// Shuffle virtual args into SysV, then call rel32
    void emitCall(Label target) {
        emitShuffleVirtualToCAbi();
        uint off = pos;
        emitU8(0xE8); emitU32(0);
        unresolved ~= UnresolvedBranch(off, target.id, BranchKind.call);
    }

    void emitLoadLabelAddress(Label target) {
        uint off = pos;
        emitU8(0x48); emitU8(0x8D); emitU8(0x05); emitU32(0);  // lea rax, [rip+disp]
        unresolved ~= UnresolvedBranch(off, target.id, BranchKind.adr);
    }

    void emitCallIndirect() {
        emitMovRR(R14, XR8);  // r12 = x8
        emitShuffleVirtualToCAbi();
        emitU8(0x41); emitU8(0xFF); emitU8(0xD6);  // call r14
    }

    void emitMoveXReg(uint src, uint dst) {
        ubyte s = src < xReg.length ? xReg[src] : R14;
        ubyte d = dst < xReg.length ? xReg[dst] : R14;
        emitMovRR(d, s);
    }

    void emitMoveX0ToX1() { emitMovRR(XR1, XR0); }
    void emitMoveX0ToX2() { emitMovRR(XR2, XR0); }
    void emitMoveX0ToX3() { emitMovRR(XR3, XR0); }
    void emitMoveX0ToX4() { emitMovRR(XR4, XR0); }
    void emitMoveX0ToX5() { emitMovRR(XR5, XR0); }
    void emitMoveX0ToX6() { emitMovRR(XR6, XR0); }
    void emitMoveX0ToX7() { emitMovRR(XR7, XR0); }
    void emitMoveX0ToX8() { emitMovRR(XR8, XR0); }
    void emitMoveX8ToX0() { emitMovRR(XR0, XR8); }
    void emitMoveX1ToX0() { emitMovRR(XR0, XR1); }
    void emitMoveX2ToX0() { emitMovRR(XR0, XR2); }
    void emitMoveX3ToX0() { emitMovRR(XR0, XR3); }
    void emitMoveX4ToX0() { emitMovRR(XR0, XR4); }
    void emitMoveX5ToX0() { emitMovRR(XR0, XR5); }
    void emitMoveX6ToX0() { emitMovRR(XR0, XR6); }
    void emitMoveX7ToX0() { emitMovRR(XR0, XR7); }
    void emitMoveX2ToX1() { emitMovRR(XR1, XR2); }
    void emitMoveX1ToX2() { emitMovRR(XR2, XR1); }
    void emitMoveX2ToX3() { emitMovRR(XR3, XR2); }
    void emitMoveX0ToX10() { emitMovRR(XR10, XR0); }
    void emitMoveX10ToX0() { emitMovRR(XR0, XR10); }

    alias emitMoveResultToArg1 = emitMoveX0ToX1;
    alias emitMoveResultToArg2 = emitMoveX0ToX2;
    alias emitMoveResultToArg3 = emitMoveX0ToX3;
    alias emitMoveResultToScratch2 = emitMoveX0ToX8;
    alias emitMoveScratch2ToResult = emitMoveX8ToX0;
    alias emitMoveArg1ToResult = emitMoveX1ToX0;
    alias emitMoveArg2ToArg1 = emitMoveX2ToX1;

    // ========== Inline call stack ==========

    void emitInlineStackPush(uint frameDataOffset) {
        // r13 = data section base (x10)
        // mov eax, [r13]
        emitU8(0x41); emitU8(0x8B); emitU8(0x45); emitU8(0x00);
        // cmp eax, [r13+4]
        emitU8(0x41); emitU8(0x3B); emitU8(0x45); emitU8(0x04);
        // jge skip (rel32) — skip rest of this sequence
        uint jcc = pos;
        emitU8(0x0F); emitU8(0x8D); emitU32(0);

        // imul r11d, eax, 24
        emitU8(0x44); emitU8(0x6B); emitU8(0xD8); emitU8(24);
        // lea r11, [r13 + r11 + 8]
        emitU8(0x4F); emitU8(0x8D); emitU8(0x5C); emitU8(0x1D); emitU8(0x08);
        // lea rax, [r13 + frameDataOffset]
        emitU8(0x49); emitU8(0x8D); emitU8(0x85); emitU32(frameDataOffset);

        // copy 24 bytes rax -> r11 using r12
        emitU8(0x4C); emitU8(0x8B); emitU8(0x20);             // mov r12, [rax]
        emitU8(0x4D); emitU8(0x89); emitU8(0x23);             // mov [r11], r12
        emitU8(0x4C); emitU8(0x8B); emitU8(0x60); emitU8(0x08); // mov r12, [rax+8]
        emitU8(0x4D); emitU8(0x89); emitU8(0x63); emitU8(0x08); // mov [r11+8], r12
        emitU8(0x4C); emitU8(0x8B); emitU8(0x60); emitU8(0x10); // mov r12, [rax+16]
        emitU8(0x4D); emitU8(0x89); emitU8(0x63); emitU8(0x10); // mov [r11+16], r12

        // add dword [r13], 1
        emitU8(0x41); emitU8(0x83); emitU8(0x45); emitU8(0x00); emitU8(0x01);

        int rel = cast(int)pos - cast(int)(jcc + 6);
        *cast(int*)(base + jcc + 2) = rel;
    }

    void emitInlineStackPop() {
        // mov eax, [r13]
        emitU8(0x41); emitU8(0x8B); emitU8(0x45); emitU8(0x00);
        // test eax, eax
        emitU8(0x85); emitU8(0xC0);
        uint jcc = pos;
        emitU8(0x0F); emitU8(0x84); emitU32(0);  // jz skip
        // sub eax, 1
        emitU8(0x83); emitU8(0xE8); emitU8(0x01);
        // mov [r13], eax
        emitU8(0x41); emitU8(0x89); emitU8(0x45); emitU8(0x00);
        int rel = cast(int)pos - cast(int)(jcc + 6);
        *cast(int*)(base + jcc + 2) = rel;
    }

    void emitPushLR() {
        emitU8(0x50);  // push rax — not used as LR; placeholder
    }
    void emitPopLR() {
        emitU8(0x58);
    }
    void emitPush(int reg) {
        ubyte r = reg < xReg.length ? xReg[reg] : RAX;
        if (r & 8) emitU8(0x41);
        emitU8(cast(ubyte)(0x50 | (r & 7)));
    }
    void emitPop(int reg) {
        ubyte r = reg < xReg.length ? xReg[reg] : RAX;
        if (r & 8) emitU8(0x41);
        emitU8(cast(ubyte)(0x58 | (r & 7)));
    }

    /// SysV → virtual register shuffle (after frame is set up, args still in SysV regs)
    private void emitSysVShuffle() {
        emitMovRR(R11, RCX);  // save SysV arg3
        emitMovRR(RAX, RDI);  // x0 = arg0
        emitMovRR(RCX, RSI);  // x1 = arg1
        // rdx already x2
        emitMovRR(RSI, R11);  // x3 = arg3
        // r8, r9 already x4, x5
    }

    void emitPrologue() {
        emitU8(0x55);                         // push rbp
        emitMovRR(RBP, RSP);                  // mov rbp, rsp
        emitU8(0x41); emitU8(0x54);           // push r12
        emitU8(0x41); emitU8(0x55);           // push r13
        frameSize = 16;
        localAlloc = 0;
        emitSysVShuffle();
    }

    void emitEpilogue() {
        emitU8(0x41); emitU8(0x5D);           // pop r13
        emitU8(0x41); emitU8(0x5C);           // pop r12
        emitU8(0x5D);                         // pop rbp
        emitU8(0xC3);                         // ret
    }

    void emitTrap() {
        emitU8(0xCC);  // int3
    }

    void emitAdrp(ubyte rd) {
        // lea rax, [rip+0] placeholder
        emitU8(0x48); emitU8(0x8D); emitU8(0x05); emitU32(0);
    }

    void emitAddImm12(ubyte rd, ubyte rn) {
        // nop — AOT reloc companion to ADRP; unused in JIT
        emitU8(0x90);
    }

    void emitExternalBranchLink() {
        emitU8(0xE8); emitU32(0);  // call rel32 placeholder
    }

    void emitPrologueWithLocals(size_t localBytes) {
        emitU8(0x55);
        emitMovRR(RBP, RSP);
        emitU8(0x41); emitU8(0x54);  // push r12
        emitU8(0x41); emitU8(0x55);  // push r13
        uint aligned = cast(uint)((localBytes + 15) & ~15);
        localAlloc = aligned;
        frameSize = 16 + aligned;
        if (aligned > 0)
            emitSubSPImm(aligned);
        emitSysVShuffle();
    }

    void emitEpilogueWithLocals(size_t localBytes) {
        if (localAlloc > 0)
            emitAddSPImm(localAlloc);
        emitU8(0x41); emitU8(0x5D);
        emitU8(0x41); emitU8(0x5C);
        emitU8(0x5D);
        emitU8(0xC3);
    }

    void emitSubSPLarge(uint amount) { emitSubSPImm(amount); }
    void emitAddSPLarge(uint amount) { emitAddSPImm(amount); }

    void emitSubSPImm(uint imm) {
        // sub rsp, imm32
        emitU8(0x48); emitU8(0x81); emitU8(0xEC); emitU32(imm);
    }

    void emitAddSPImm(uint imm) {
        emitU8(0x48); emitU8(0x81); emitU8(0xC4); emitU32(imm);
    }

    void emitStorePtrToSP(uint off) {
        // mov [rsp+off], rax
        emitU8(0x48); emitU8(0x89); emitU8(0x84); emitU8(0x24); emitU32(off);
    }

    void emitStoreLocal(size_t off) { emitStore64Rbp(XR0, localDisp(off)); }
    void emitStoreLocalFromX1(size_t off) { emitStore64Rbp(XR1, localDisp(off)); }
    void emitLoadLocal(size_t off) { emitLoad64Rbp(XR0, localDisp(off)); }
    void emitStoreLocal32(size_t off) { emitStore32Rbp(XR0, localDisp(off)); }
    void emitStoreLocal32FromX1(size_t off) { emitStore32Rbp(XR1, localDisp(off)); }
    void emitStoreLocal32FromX2(size_t off) { emitStore32Rbp(XR2, localDisp(off)); }
    void emitStoreLocal32FromX3(size_t off) { emitStore32Rbp(XR3, localDisp(off)); }
    alias emitStoreArg1ToLocal32 = emitStoreLocal32FromX1;
    alias emitStoreArg2ToLocal32 = emitStoreLocal32FromX2;
    alias emitStoreArg3ToLocal32 = emitStoreLocal32FromX3;

    void emitStorePtr(size_t off) {
        assert(off % 8 == 0, "emitStorePtr: offset not 8-byte aligned");
        emitStoreLocal(off);
    }
    void emitLoadPtr(size_t off) {
        assert(off % 8 == 0, "emitLoadPtr: offset not 8-byte aligned");
        emitLoadLocal(off);
    }
    void emitLoadLocal32(size_t off) { emitLoad32Rbp(XR0, localDisp(off)); }

    // f64 locals: xmm0 / xmm1
    void emitStoreLocalF64(size_t off) {
        int d = localDisp(off);
        emitU8(0xF2); emitU8(0x0F); emitU8(0x11); emitU8(0x85); emitU32(cast(uint)d); // movsd [rbp+d], xmm0
    }
    void emitStoreLocalF64FromD1(size_t off) {
        int d = localDisp(off);
        emitU8(0xF2); emitU8(0x0F); emitU8(0x11); emitU8(0x8D); emitU32(cast(uint)d);
    }
    void emitStoreLocalF64FromD2(size_t off) {
        int d = localDisp(off);
        emitU8(0xF2); emitU8(0x0F); emitU8(0x11); emitU8(0x95); emitU32(cast(uint)d);
    }
    void emitStoreLocalF64FromD3(size_t off) {
        int d = localDisp(off);
        emitU8(0xF2); emitU8(0x0F); emitU8(0x11); emitU8(0x9D); emitU32(cast(uint)d);
    }
    void emitLoadLocalF64(size_t off) {
        int d = localDisp(off);
        emitU8(0xF2); emitU8(0x0F); emitU8(0x10); emitU8(0x85); emitU32(cast(uint)d);
    }
    void emitLoadLocalF64ToD1(size_t off) {
        int d = localDisp(off);
        emitU8(0xF2); emitU8(0x0F); emitU8(0x10); emitU8(0x8D); emitU32(cast(uint)d);
    }
    void emitMoveD0ToD1() {
        emitU8(0xF2); emitU8(0x0F); emitU8(0x10); emitU8(0xC8); // movsd xmm1, xmm0
    }
    void emitMoveX0ToD0() {
        emitU8(0x66); emitU8(0x48); emitU8(0x0F); emitU8(0x6E); emitU8(0xC0); // movq xmm0, rax
    }
    void emitMoveX0ToD1() {
        emitU8(0x66); emitU8(0x48); emitU8(0x0F); emitU8(0x6E); emitU8(0xC8);
    }
    void emitMoveX0ToD2() {
        emitU8(0x66); emitU8(0x48); emitU8(0x0F); emitU8(0x6E); emitU8(0xD0);
    }
    void emitMoveX0ToD3() {
        emitU8(0x66); emitU8(0x48); emitU8(0x0F); emitU8(0x6E); emitU8(0xD8);
    }
    void emitMoveW0ToS0() {
        emitU8(0x66); emitU8(0x0F); emitU8(0x6E); emitU8(0xC0); // movd xmm0, eax
    }
    void emitMoveW0ToS1() {
        emitU8(0x66); emitU8(0x0F); emitU8(0x6E); emitU8(0xC8);
    }
    void emitMoveW0ToS2() {
        emitU8(0x66); emitU8(0x0F); emitU8(0x6E); emitU8(0xD0);
    }
    void emitMoveW0ToS3() {
        emitU8(0x66); emitU8(0x0F); emitU8(0x6E); emitU8(0xD8);
    }
    void emitStoreLocalF32(size_t off) {
        int d = localDisp(off);
        emitU8(0xF3); emitU8(0x0F); emitU8(0x11); emitU8(0x85); emitU32(cast(uint)d);
    }
    void emitStoreLocalF32FromS1(size_t off) {
        int d = localDisp(off);
        emitU8(0xF3); emitU8(0x0F); emitU8(0x11); emitU8(0x8D); emitU32(cast(uint)d);
    }
    void emitStoreLocalF32FromS2(size_t off) {
        int d = localDisp(off);
        emitU8(0xF3); emitU8(0x0F); emitU8(0x11); emitU8(0x95); emitU32(cast(uint)d);
    }
    void emitStoreLocalF32FromS3(size_t off) {
        int d = localDisp(off);
        emitU8(0xF3); emitU8(0x0F); emitU8(0x11); emitU8(0x9D); emitU32(cast(uint)d);
    }
    void emitLoadLocalF32(size_t off) {
        int d = localDisp(off);
        emitU8(0xF3); emitU8(0x0F); emitU8(0x10); emitU8(0x85); emitU32(cast(uint)d);
    }
    void emitConvertF64ToF32() {
        emitU8(0xF2); emitU8(0x0F); emitU8(0x5A); emitU8(0xC0); // cvtsd2ss xmm0, xmm0
    }
    void emitConvertF32ToF64() {
        emitU8(0xF3); emitU8(0x0F); emitU8(0x5A); emitU8(0xC0); // cvtss2sd xmm0, xmm0
    }
    void emitConvertF32ToI32() {
        emitU8(0xF3); emitU8(0x0F); emitU8(0x2C); emitU8(0xC0); // cvttss2si eax, xmm0
    }

    void emitLoadPtrFromX0Offset(size_t off) {
        // mov rax, [rax + off]
        emitU8(0x48); emitU8(0x8B); emitU8(0x80); emitU32(cast(uint)off);
    }

    void emitIncLocal32(size_t off) {
        int d = localDisp(off);
        emitU8(0xFF); emitU8(0x85); emitU32(cast(uint)d); // inc dword [rbp+d]
        emitLoadLocal32(off);
    }

    void emitLoadStackPointer() {
        emitMovRR(RAX, RSP);
    }

    void emitLoadFromPointer(size_t off) {
        // mov eax, [rax + off]
        emitU8(0x8B); emitU8(0x80); emitU32(cast(uint)off);
    }

    void emitLoadFromPointer64(size_t off) {
        assert(off % 8 == 0, "emitLoadFromPointer64: offset not 8-byte aligned");
        emitU8(0x48); emitU8(0x8B); emitU8(0x80); emitU32(cast(uint)off);
    }

    void emitLoadByteFromPointer(size_t off) {
        emitU8(0x0F); emitU8(0xB6); emitU8(0x80); emitU32(cast(uint)off); // movzx eax, byte [rax+off]
    }

    void emitStoreToPointer(size_t off) {
        // mov [rax+off], ecx
        emitU8(0x89); emitU8(0x88); emitU32(cast(uint)off);
    }

    void emitStoreByteToPointer(size_t off) {
        emitU8(0x88); emitU8(0x88); emitU32(cast(uint)off); // mov [rax+off], cl
    }

    void emitStoreToPointerFromX9(size_t off) {
        // mov [rax+off], r11d
        emitU8(0x44); emitU8(0x89); emitU8(0x98); emitU32(cast(uint)off);
    }

    void emitStoreToPointerFromX9_64(size_t off) {
        emitU8(0x4C); emitU8(0x89); emitU8(0x98); emitU32(cast(uint)off);
    }

    // ========== Finalize ==========

    bool finalize() {
        if (!patchBranches()) return false;

        size_t codeLen = offset;
        enum PAGE_SIZE = 4096;
        size_t mapSize = (codeLen + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
        if (mapSize == 0) mapSize = PAGE_SIZE;

        void* execMem = mmap(null, mapSize,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT,
            -1, 0);
        if (execMem == MAP_FAILED) return false;

        memcpy(execMem, base, codeLen);
        free(base);
        base = cast(ubyte*)execMem;
        capacity = mapSize;
        finalized = true;
        return mprotect(base, capacity, PROT_READ | PROT_EXEC) == 0;
    }

    ubyte[] finalizeRelocatable() {
        if (!patchBranches()) return null;
        return base[0 .. offset].dup;
    }

    private bool patchBranches() {
        foreach (ref br; unresolved) {
            Label* target;
            foreach (ref l; labels) {
                if (l.id == br.labelId) {
                    target = &l;
                    break;
                }
            }
            if (!target || !target.bound) return false;

            uint instrLen;
            uint dispOff;
            final switch (br.kind) {
                case BranchKind.unconditional:
                case BranchKind.call:
                    instrLen = 5; dispOff = 1; break;
                case BranchKind.ifZero:
                case BranchKind.ifNonZero:
                case BranchKind.conditional:
                    instrLen = 6; dispOff = 2; break;
                case BranchKind.adr:
                    instrLen = 7; dispOff = 3; break;
            }
            int rel = cast(int)target.offset - cast(int)(br.offset + instrLen);
            *cast(int*)(base + br.offset + dispOff) = rel;
        }
        return true;
    }

    T getFunc(T)(size_t off = 0) {
        return cast(T)(base + off);
    }

    void freeBuffer() {
        if (base) {
            if (finalized)
                munmap(base, capacity);
            else
                free(base);
            base = null;
        }
    }
}

extern(C) {
    alias NullaryFn = long function();
    alias UnaryFn = long function(long);
    alias BinaryFn = long function(long, long);
}
