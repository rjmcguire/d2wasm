/**
 * Chain dispatch stencils for ARM64.
 * 
 * Each class gets a dispatch fragment:
 *   - Load object's typeId
 *   - Compare against this class's typeId  
 *   - If match, jump to method
 *   - Otherwise, jump to next handler in chain
 * 
 * The chain is assembled at link time by patching "next" pointers.
 */
module chain_dispatch_stencils;

/**
 * Layout of a dispatch chain entry (in generated code):
 * 
 *   entry:
 *       ldr w1, [x0]           // Load obj.typeId (assume at offset 0)
 *       cmp w1, #TYPE_ID       // Compare with this class's ID (HOLE)
 *       b.ne next              // If not match, go to next
 *       b method_impl          // Jump to method (HOLE)
 *   next:
 *       b next_handler         // Jump to next in chain (HOLE, patchable)
 * 
 * Total: 16 bytes (4 instructions)
 * 
 * Holes:
 *   - TYPE_ID: 12-bit immediate in CMP instruction
 *   - method_impl: 26-bit offset in B instruction
 *   - next_handler: 26-bit offset in B instruction (patchable)
 */

// ARM64 instruction encoding helpers
uint encodeCmpImm(uint reg, uint imm12) {
    // CMP Wn, #imm12 is encoded as SUBS WZR, Wn, #imm12
    // 0111 0001 00 [imm12] [Rn:5] [11111]
    return 0x7100001F | (imm12 << 10) | (reg << 5);
}

uint encodeBCond(uint cond, int offset) {
    // B.cond: 0101 0100 [imm19] 0 [cond:4]
    // offset is in instructions (divide byte offset by 4)
    uint imm19 = (offset >> 2) & 0x7FFFF;
    return 0x54000000 | (imm19 << 5) | cond;
}

uint encodeB(int offset) {
    // B: 0001 01 [imm26]
    uint imm26 = (offset >> 2) & 0x3FFFFFF;
    return 0x14000000 | imm26;
}

uint encodeLdrW(uint rt, uint rn, uint offset) {
    // LDR Wt, [Xn, #offset] (unsigned offset, scaled by 4)
    // 1011 1001 01 [imm12] [Rn:5] [Rt:5]
    uint imm12 = (offset / 4) & 0xFFF;
    return 0xB9400000 | (imm12 << 10) | (rn << 5) | rt;
}

// Condition codes
enum ARM64Cond {
    EQ = 0x0,  // Equal
    NE = 0x1,  // Not equal
    // ... others
}

/**
 * Generate a chain dispatch entry for a single class.
 * 
 * Returns the bytes for:
 *   ldr w1, [x0, #typeIdOffset]
 *   cmp w1, #typeId
 *   b.ne +8  (skip to next handler jump)
 *   b methodOffset
 *   b nextHandlerOffset  (initially 0, to be patched)
 */
ubyte[] generateChainEntry(uint typeId, int methodOffset, uint typeIdOffset = 0) {
    ubyte[] code;
    code.length = 20;  // 5 instructions
    
    // ldr w1, [x0, #typeIdOffset]
    uint ldr = encodeLdrW(1, 0, typeIdOffset);
    code[0..4] = (cast(ubyte*)&ldr)[0..4];
    
    // cmp w1, #typeId
    uint cmp = encodeCmpImm(1, typeId & 0xFFF);
    code[4..8] = (cast(ubyte*)&cmp)[0..4];
    
    // b.ne +8 (skip method jump, go to next handler)
    uint bne = encodeBCond(ARM64Cond.NE, 8);
    code[8..12] = (cast(ubyte*)&bne)[0..4];
    
    // b method (relative offset)
    uint bMethod = encodeB(methodOffset);
    code[12..16] = (cast(ubyte*)&bMethod)[0..4];
    
    // b next_handler (placeholder, offset 0 = self-loop until patched)
    uint bNext = encodeB(0);  // Will be patched
    code[16..20] = (cast(ubyte*)&bNext)[0..4];
    
    return code;
}

/**
 * Patch the "next handler" offset in a chain entry.
 * entryCode should point to the start of a chain entry.
 * offset is relative from the B instruction (entry + 16).
 */
void patchNextHandler(ubyte[] entryCode, int offset) {
    uint bNext = encodeB(offset);
    entryCode[16..20] = (cast(ubyte*)&bNext)[0..4];
}

/**
 * Generate the terminal trap handler.
 */
ubyte[] generateTrapHandler() {
    ubyte[] code;
    code.length = 4;
    
    // brk #0 (debug trap)
    uint brk = 0xD4200000;
    code[0..4] = (cast(ubyte*)&brk)[0..4];
    
    return code;
}

// Test
unittest {
    auto entry = generateChainEntry(42, 100);
    assert(entry.length == 20);
    
    // Check ldr w1, [x0]
    uint ldr = *cast(uint*)(entry.ptr);
    assert((ldr & 0xFFC00000) == 0xB9400000, "Should be LDR");
    
    // Check cmp w1, #42
    uint cmp = *cast(uint*)(entry.ptr + 4);
    assert((cmp >> 10) & 0xFFF == 42, "Immediate should be 42");
}
