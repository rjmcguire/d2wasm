/**
 * Native Code Generator Interface
 * 
 * Defines the abstract interface for native code generation.
 * Architecture-specific implementations (ARM64, x86_64) implement this interface.
 * 
 * This allows the high-level compilation logic in NativeCompiledFunction
 * to be architecture-agnostic.
 */
module codegen.native.codegen_interface;

import codegen.native.stencil_catalog;

/**
 * Label for branch targets.
 * Used across all architectures.
 */
struct Label {
    int id;
    bool bound;      // Has the label been placed?
    uint offset;     // Offset in code buffer (valid if bound)
}

/**
 * Abstract interface for native code generation.
 * 
 * Architecture-specific backends implement this interface.
 * The interface is designed around abstract operations, not specific
 * registers, to enable portability.
 * 
 * Register model (abstract):
 *   result   - where computation results go (ARM64: x0, x86_64: rax)
 *   arg0-3   - function arguments (ARM64: x0-x3, x86_64: rdi,rsi,rdx,rcx)
 *   scratch  - temporary register (ARM64: x9, x86_64: r11)
 */
interface INativeCodeGen {
    
    // ===== Buffer Management =====
    
    /// Current position in code buffer
    @property uint pos();
    
    /// Base address of code buffer (for computing function pointers)
    @property ubyte* base();
    
    /// Finalize the code (resolve branches, set permissions)
    bool finalize();
    
    /// Free allocated memory
    void free();
    
    // ===== Stencil Emission =====
    
    /// Emit a stencil by name
    void* emitStencil(string name);
    
    /// Emit a stencil with a 32-bit immediate patched
    void* emitStencilImm32(string name, int value);
    
    /// Emit a stencil with a 64-bit immediate patched
    void* emitStencilImm64(string name, ulong value);
    
    // ===== Arithmetic Operations =====
    // All operate on: result = result op arg1
    
    void emitAdd();
    void emitSub();
    void emitMul();
    void emitDiv();
    void emitMod();
    
    // ===== Bitwise Operations =====
    
    void emitAnd();
    void emitOr();
    void emitXor();
    void emitShl();
    void emitShr();
    
    // ===== Comparison Operations =====
    // Result is 0 or 1
    
    void emitEq();
    void emitNe();
    void emitLt();
    void emitLe();
    void emitGt();
    void emitGe();
    
    // ===== Immediate Loading =====
    
    /// Load 32-bit immediate into result register
    void emitLoadImm(int value);
    
    /// Load 64-bit immediate into result register
    void emitLoadImm64(ulong value);
    
    /// Load 64-bit immediate into scratch register (preserves args)
    void emitLoadImm64ToScratch(ulong value);
    
    // ===== Register Moves =====
    
    /// Move result to arg1 (for binary operations)
    void emitMoveResultToArg1();
    
    /// Move result to arg2
    void emitMoveResultToArg2();
    
    /// Move result to arg3
    void emitMoveResultToArg3();
    
    /// Move result to scratch register (scratch1)
    void emitMoveResultToScratch();
    
    /// Move scratch to result
    void emitMoveScratchToResult();
    
    /// Move result to scratch2 (secondary scratch register)
    void emitMoveResultToScratch2();
    
    /// Move scratch2 to result
    void emitMoveScratch2ToResult();
    
    /// Move arg1 to result
    void emitMoveArg1ToResult();
    
    /// Move arg2 to arg1
    void emitMoveArg2ToArg1();
    
    // ===== Local Variable Access =====
    // Uses frame-relative addressing
    
    /// Load 32-bit local variable into result
    void emitLoadLocal32(uint offset);
    
    /// Store result to 32-bit local variable
    void emitStoreLocal32(uint offset);
    
    /// Store arg1 to 32-bit local variable (for parameter spilling)
    void emitStoreArg1ToLocal32(uint offset);
    
    /// Store arg2 to 32-bit local variable
    void emitStoreArg2ToLocal32(uint offset);
    
    /// Store arg3 to 32-bit local variable
    void emitStoreArg3ToLocal32(uint offset);
    
    /// Load 64-bit local variable into result
    void emitLoadLocal64(uint offset);
    
    /// Store result to 64-bit local variable
    void emitStoreLocal64(uint offset);
    
    // ===== Memory Access =====
    
    /// Load 32-bit from address in result + offset
    void emitLoadFromPointer32(uint offset);
    
    /// Store arg1 to address in result + offset
    void emitStoreToPointer32(uint offset);
    
    // ===== Stack Frame =====
    
    /// Emit function prologue
    void emitPrologue();
    
    /// Emit function prologue with space for locals
    void emitPrologueWithLocals(uint size);
    
    /// Emit function epilogue
    void emitEpilogue();
    
    /// Emit function epilogue (restoring locals space)
    void emitEpilogueWithLocals(uint size);
    
    /// Get current stack/frame pointer into result
    void emitLoadStackPointer();
    
    // ===== Control Flow =====
    
    /// Create a new unbound label
    Label newLabel();
    
    /// Bind a label to current position
    void bindLabel(ref Label label);
    
    /// Emit unconditional branch to label
    void emitBranch(Label target);
    
    /// Emit branch if result is zero
    void emitBranchIfZero(Label target);
    
    /// Emit branch if result is non-zero
    void emitBranchIfNonZero(Label target);
    
    /// Emit direct call to label
    void emitCall(Label target);
    
    /// Emit return
    void emitRet();
    
    // ===== Indirect Calls =====
    
    /// Load pointer from address in scratch
    void emitLoadPtrFromScratch();
    
    /// Call function at address in scratch
    void emitCallIndirect();
    
    /// Complete indirect call sequence: load slot address, load pointer, call
    void emitIndirectCall(ulong slotAddress);
    
    // ===== Architecture Info =====
    
    /// Get the architecture name
    string architecture();
}

/**
 * Create a native code generator for the specified architecture.
 * Returns null if architecture is not supported.
 */
INativeCodeGen createNativeCodeGen(string arch, size_t codeSize = 64 * 1024) {
    switch (arch) {
        case "arm64":
        case "aarch64":
            import codegen.native.arm64.codegen;
            return ARM64CodeGen.create(codeSize);
        
        // Future: x86_64
        // case "x86_64":
        // case "amd64":
        //     import codegen.native.x86_64.codegen;
        //     return X86_64CodeGen.create(codeSize);
        
        default:
            return null;
    }
}

/**
 * Get the native architecture for the current host.
 */
string hostArchitecture() {
    version(AArch64) {
        return "arm64";
    }
    else version(X86_64) {
        return "x86_64";
    }
    else {
        return "unknown";
    }
}

/**
 * Create a native code generator for the current host architecture.
 */
INativeCodeGen createHostNativeCodeGen(size_t codeSize = 64 * 1024) {
    return createNativeCodeGen(hostArchitecture(), codeSize);
}
