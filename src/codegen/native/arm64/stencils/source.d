/**
 * ARM64 Stencil Source Functions
 * 
 * These D functions are compiled with LDC to ARM64 machine code,
 * then extracted to create the stencil table.
 * 
 * Compile: ldc2 -O3 -c --frame-pointer=none -of=stencils.o source.d
 * Extract: rdmd extract_stencils.d stencils.o
 * 
 * ARM64 Calling Convention:
 * - Arguments: x0, x1, x2, x3 (we use x0=arg0/result, x1=arg1, x2=arg2, x3=arg3)
 * - Return: x0
 * - Scratch: x8, x9 (caller-saved, safe to clobber)
 * - Frame pointer: x29
 * - Link register: x30
 * - Stack pointer: sp
 */
module arm64.stencils.source;

// Magic hole markers - distinctive values we can find in the binary
enum HOLE1 = 0xDEAD_0001;
enum HOLE2 = 0xDEAD_0002;
enum HOLE3 = 0xDEAD_0003;
enum HOLE4 = 0xDEAD_0004;

extern(C) @nogc nothrow:

// ============================================================================
// Arithmetic (x0 op x1 -> x0)
// ============================================================================

long add_i32(long a, long b) { return a + b; }
long sub_i32(long a, long b) { return a - b; }
long mul_i32(long a, long b) { return a * b; }
long div_i32(long a, long b) { return a / b; }
long mod_i32(long a, long b) { return a % b; }
long neg_i32(long a) { return -a; }

// ============================================================================
// Bitwise (x0 op x1 -> x0)
// ============================================================================

long and_i32(long a, long b) { return a & b; }
long or_i32(long a, long b)  { return a | b; }
long xor_i32(long a, long b) { return a ^ b; }
long shl_i32(long a, long b) { return a << b; }
long shr_i32(long a, long b) { return a >> b; }
long not_i32(long a) { return ~a; }

// ============================================================================
// Comparison (x0 op x1 -> 0 or 1 in x0)
// ============================================================================

long eq_i32(long a, long b) { return a == b ? 1 : 0; }
long ne_i32(long a, long b) { return a != b ? 1 : 0; }
long lt_i32(long a, long b) { return a < b ? 1 : 0; }
long le_i32(long a, long b) { return a <= b ? 1 : 0; }
long gt_i32(long a, long b) { return a > b ? 1 : 0; }
long ge_i32(long a, long b) { return a >= b ? 1 : 0; }

// ============================================================================
// Immediates (holes get patched)
// ============================================================================

/// Load 32-bit immediate into x0 (uses HOLE1 low 16, HOLE2 high 16)
long load_imm32() {
    return HOLE1;  // Compiler will emit MOV + MOVK
}

/// Load 64-bit immediate into x0 (uses all 4 holes)
long load_imm64() {
    return (cast(long)HOLE4 << 48) | (cast(long)HOLE3 << 32) | 
           (cast(long)HOLE2 << 16) | cast(long)HOLE1;
}

/// Load 64-bit immediate into x9 (scratch register, preserves x0-x3)
long load_imm64_to_scratch() {
    // We can't easily express "load into x9" in D
    // This will be hand-crafted or use inline asm
    // For now, placeholder that loads to x0
    return (cast(long)HOLE4 << 48) | (cast(long)HOLE3 << 32) | 
           (cast(long)HOLE2 << 16) | cast(long)HOLE1;
}

// ============================================================================
// Memory Access
// ============================================================================

/// Load 32-bit from [x0 + HOLE1]
long load_i32(long* base) {
    return *(cast(int*)(cast(ubyte*)base + HOLE1));
}

/// Store 32-bit x1 to [x0 + HOLE1]
void store_i32(long* base, long val) {
    *(cast(int*)(cast(ubyte*)base + HOLE1)) = cast(int)val;
}

/// Load 64-bit from [x0 + HOLE1]
long load_i64(long* base) {
    return *(cast(long*)(cast(ubyte*)base + HOLE1));
}

/// Store 64-bit x1 to [x0 + HOLE1]
void store_i64(long* base, long val) {
    *(cast(long*)(cast(ubyte*)base + HOLE1)) = val;
}

// ============================================================================
// Local Variable Access (frame pointer relative)
// These assume x29 is the frame pointer
// ============================================================================

/// Load 32-bit local from [fp + HOLE1]
long load_local_i32() {
    // Access relative to frame pointer
    // The actual implementation uses inline asm or is hand-crafted
    long* fp;
    asm @nogc nothrow {
        "mov %0, x29" : "=r"(fp);
    }
    return *(cast(int*)(cast(ubyte*)fp + HOLE1));
}

/// Store 32-bit x0 to [fp + HOLE1]  
void store_local_i32(long val) {
    long* fp;
    asm @nogc nothrow {
        "mov %0, x29" : "=r"(fp);
    }
    *(cast(int*)(cast(ubyte*)fp + HOLE1)) = cast(int)val;
}

/// Load 64-bit local from [fp + HOLE1]
long load_local_i64() {
    long* fp;
    asm @nogc nothrow {
        "mov %0, x29" : "=r"(fp);
    }
    return *(cast(long*)(cast(ubyte*)fp + HOLE1));
}

/// Store 64-bit x0 to [fp + HOLE1]
void store_local_i64(long val) {
    long* fp;
    asm @nogc nothrow {
        "mov %0, x29" : "=r"(fp);
    }
    *(cast(long*)(cast(ubyte*)fp + HOLE1)) = val;
}

// ============================================================================
// Indirect Calls
// ============================================================================

/// Load pointer from address in x9, result in x9
/// LDR x9, [x9]
void load_ptr_indirect() {
    // This needs to be hand-crafted: LDR x9, [x9]
    // Can't express in D without inline asm targeting x9
}

/// Call function whose address is in x9
/// BLR x9
void call_indirect() {
    // This needs to be hand-crafted: BLR x9
    // Can't express in D
}

// ============================================================================
// Stack Frame
// ============================================================================

/// Function prologue (save fp, lr)
void prologue() {
    // STP x29, x30, [sp, #-16]!
    // MOV x29, sp
}

/// Function prologue with locals (save fp, lr, allocate stack)
void prologue_with_locals() {
    // STP x29, x30, [sp, #-16]!
    // MOV x29, sp
    // SUB sp, sp, #HOLE1
}

/// Function epilogue (restore fp, lr, return)
void epilogue() {
    // LDP x29, x30, [sp], #16
    // RET
}

/// Function epilogue with locals
void epilogue_with_locals() {
    // ADD sp, sp, #HOLE1
    // LDP x29, x30, [sp], #16
    // RET
}

// ============================================================================
// Register Moves
// ============================================================================

/// Move x0 to x1
void move_result_to_arg1() {
    // MOV x1, x0
}

/// Move x0 to x2
void move_result_to_arg2() {
    // MOV x2, x0
}

/// Move x0 to x3
void move_result_to_arg3() {
    // MOV x3, x0
}

/// Move x0 to x9 (scratch)
void move_result_to_scratch() {
    // MOV x9, x0
}

/// Move x9 to x0
void move_scratch_to_result() {
    // MOV x0, x9
}

/// Move x1 to x0
void move_arg1_to_result() {
    // MOV x0, x1
}

// ============================================================================
// Stack Pointer
// ============================================================================

/// Get frame pointer into x0
long get_frame_pointer() {
    long fp;
    asm @nogc nothrow {
        "mov %0, x29" : "=r"(fp);
    }
    return fp;
}

// ============================================================================
// Return
// ============================================================================

void return_void() {
    // RET
}

long return_val(long v) {
    return v;  // Value already in x0, just RET
}
