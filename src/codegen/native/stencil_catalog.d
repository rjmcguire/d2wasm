/**
 * Stencil Catalog - Required stencils for native backends
 * 
 * Every architecture backend must provide implementations for these stencils.
 * This ensures the code generator can remain architecture-agnostic.
 * 
 * Calling convention (abstract):
 * - Arguments: arg0, arg1, arg2, arg3 (mapped to registers by backend)
 * - Return: result register (mapped by backend)
 * - Scratch: backends may use additional scratch registers
 */
module codegen.native.stencil_catalog;

/**
 * Categories of stencils that backends must implement.
 */
enum StencilCategory {
    Arithmetic,
    Bitwise,
    Comparison,
    Memory,
    Immediate,
    IndirectCall,
    StackFrame,
    RegisterMove,
}

/**
 * The canonical list of stencils every native backend must provide.
 * 
 * Naming convention:
 * - Operations include type suffix: _i32, _i64
 * - Memory operations: load_*, store_*
 * - Register moves: move_*_to_*
 */
enum RequiredStencil : string {
    // ===== Arithmetic (arg0 op arg1 -> result) =====
    add_i32 = "add_i32",
    sub_i32 = "sub_i32",
    mul_i32 = "mul_i32",
    div_i32 = "div_i32",
    mod_i32 = "mod_i32",
    neg_i32 = "neg_i32",           // Unary negation
    
    // ===== Bitwise (arg0 op arg1 -> result) =====
    and_i32 = "and_i32",
    or_i32 = "or_i32",
    xor_i32 = "xor_i32",
    shl_i32 = "shl_i32",
    shr_i32 = "shr_i32",
    not_i32 = "not_i32",           // Bitwise NOT
    
    // ===== Comparison (arg0 op arg1 -> 0 or 1) =====
    eq_i32 = "eq_i32",
    ne_i32 = "ne_i32",
    lt_i32 = "lt_i32",
    le_i32 = "le_i32",
    gt_i32 = "gt_i32",
    ge_i32 = "ge_i32",
    
    // ===== Memory (base + offset) =====
    load_i32 = "load_i32",         // Load 32-bit from [base + hole]
    store_i32 = "store_i32",       // Store 32-bit to [base + hole]
    load_i64 = "load_i64",         // Load 64-bit from [base + hole]
    store_i64 = "store_i64",       // Store 64-bit to [base + hole]
    
    // ===== Immediate loading =====
    load_imm32 = "load_imm32",     // Load 32-bit immediate (2 holes: lo, hi)
    load_imm64 = "load_imm64",     // Load 64-bit immediate (4 holes)
    load_imm64_to_scratch = "load_imm64_to_scratch",  // Load 64-bit to scratch reg
    
    // ===== Indirect calls =====
    load_ptr_indirect = "load_ptr_indirect",  // Load pointer from [scratch]
    call_indirect = "call_indirect",          // Call function at scratch reg
    
    // ===== Stack frame =====
    prologue = "prologue",                     // Function entry (no locals)
    prologue_with_locals = "prologue_with_locals",  // Entry with stack space (hole: size)
    epilogue = "epilogue",                     // Function exit (no locals)
    epilogue_with_locals = "epilogue_with_locals",  // Exit with stack restore (hole: size)
    
    // ===== Register moves =====
    // These move between abstract "slots" - backend maps to actual registers
    move_result_to_arg1 = "move_result_to_arg1",    // For binary ops
    move_result_to_arg2 = "move_result_to_arg2",
    move_result_to_arg3 = "move_result_to_arg3",
    move_result_to_scratch = "move_result_to_scratch",
    move_scratch_to_result = "move_scratch_to_result",
    move_arg1_to_result = "move_arg1_to_result",
    
    // ===== Local variable access =====
    load_local_i32 = "load_local_i32",    // Load from stack frame (hole: offset)
    store_local_i32 = "store_local_i32",  // Store to stack frame (hole: offset)
    load_local_i64 = "load_local_i64",
    store_local_i64 = "store_local_i64",
    
    // ===== Stack pointer =====
    get_frame_pointer = "get_frame_pointer",  // Load frame pointer to result
    
    // ===== Return =====
    return_void = "return_void",
    return_val = "return_val",
    
    // ===== Inline Call Stack Tracking =====
    // These track function calls for error reporting without FFI overhead.
    // Data section base must be in a designated register (scratch2 on ARM64 = x10)
    //
    // Stack layout in data section:
    //   [0]:   depth (i32)
    //   [4]:   maxDepth (i32) = 64
    //   [8]:   frames[64] - array of InlineFrame (24 bytes each)
    //
    // InlineFrame layout (24 bytes):
    //   [0]:  nameOffset (i32)
    //   [4]:  nameLen (i32)
    //   [8]:  fileOffset (i32)
    //   [12]: fileLen (i32)
    //   [16]: line (i32)
    //   [20]: column (i32)
    
    inline_stack_push = "inline_stack_push",  // hole: frameDataOffset
    inline_stack_pop = "inline_stack_pop",    // no holes
}

/**
 * Hole kinds for patching immediates into stencils.
 */
enum HoleKind : ubyte {
    // 16-bit immediate pieces (for load_imm32, load_imm64)
    imm16_0,      // Bits 0-15
    imm16_1,      // Bits 16-31
    imm16_2,      // Bits 32-47
    imm16_3,      // Bits 48-63
    
    // Stack frame offsets
    frame_offset,
    
    // Memory offsets
    mem_offset,
    
    // Branch offsets (for hand-crafted branch patching)
    branch_offset,
}

/**
 * A hole in a stencil that needs patching.
 */
struct StencilHole {
    uint offset;      // Byte offset in stencil where hole is
    HoleKind kind;    // What kind of value to patch
    ubyte holeIndex;  // Which hole (0-3 for immediates)
}

/**
 * A stencil: raw bytes with holes to patch.
 */
struct Stencil {
    string name;
    immutable(ubyte)[] code;
    immutable(StencilHole)[] holes;
}

/**
 * Interface that all architecture backends must implement.
 */
interface NativeStencilProvider {
    /// Get a stencil by name
    const(Stencil)* getStencil(string name);
    
    /// Check if all required stencils are available
    bool validateCatalog();
    
    /// Get the architecture name (e.g., "arm64", "x86_64")
    string architecture();
}

/**
 * Validate that a stencil provider has all required stencils.
 */
bool validateStencilProvider(NativeStencilProvider provider) {
    import std.traits : EnumMembers;
    
    foreach (required; EnumMembers!RequiredStencil) {
        if (provider.getStencil(required) is null) {
            return false;
        }
    }
    return true;
}

/**
 * Get missing stencils from a provider.
 */
string[] getMissingStencils(NativeStencilProvider provider) {
    import std.traits : EnumMembers;
    
    string[] missing;
    foreach (required; EnumMembers!RequiredStencil) {
        if (provider.getStencil(required) is null) {
            missing ~= required;
        }
    }
    return missing;
}
