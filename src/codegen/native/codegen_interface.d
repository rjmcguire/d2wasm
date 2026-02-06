/**
 * Native Code Generator Interface
 * 
 * Defines the abstract interface for native code generation.
 * Architecture-specific implementations (ARM64, x86_64) implement this interface.
 * 
 * This allows the high-level compilation logic in NativeCompiledFunction
 * to be architecture-agnostic.
 * 
 * Also contains shared native infrastructure:
 * - NativeDataSection: mmap'd memory for CTFE data
 * - NativeCTFEContext: execution context with error handling
 * - HostFunctionTable: registry for host functions callable from native code
 */
module codegen.native.codegen_interface;

import codegen.native.stencil_catalog;
import core.sys.posix.sys.mman;
import core.stdc.string : memcpy;

// macOS-specific mmap flags not in D's stdlib
version (OSX) {
    enum MAP_ANONYMOUS = 0x1000;
    enum MAP_JIT = 0x0800;
}

// setjmp/longjmp - D's stdlib doesn't have these for macOS, so we define them ourselves
version (OSX) {
    version (AArch64) {
        // macOS ARM64: jmp_buf is 192 bytes (24 * 8)
        alias jmp_buf = long[24];
    } else version (X86_64) {
        // macOS x86_64: jmp_buf is 148 bytes, align to 19 longs
        alias jmp_buf = long[19];
    } else {
        static assert(false, "Unsupported macOS architecture for setjmp");
    }
} else version (linux) {
    // Linux uses the POSIX definitions
    import core.sys.posix.setjmp : jmp_buf;
} else {
    static assert(false, "Unsupported platform for setjmp");
}

// Declare setjmp/longjmp as extern(C)
extern(C) nothrow @nogc {
    int setjmp(ref jmp_buf env);
    void longjmp(ref jmp_buf env, int val);
}
// ============================================================================
// CTFE Error Handling
// ============================================================================

/**
 * Error types that can occur during native CTFE execution.
 * Used with longjmp to abort execution and report errors.
 */
enum CTFEErrorKind {
    None = 0,
    DivByZero = 1,
    OutOfBounds = 2,
    NullDeref = 3,
    OutOfMemory = 4,
    Overflow = 5,
}

/**
 * Convert error kind to human-readable message.
 */
string ctfeErrorMessage(CTFEErrorKind kind) {
    final switch (kind) {
        case CTFEErrorKind.None: return "no error";
        case CTFEErrorKind.DivByZero: return "integer divide by zero";
        case CTFEErrorKind.OutOfBounds: return "array index out of bounds";
        case CTFEErrorKind.NullDeref: return "null pointer dereference";
        case CTFEErrorKind.OutOfMemory: return "CTFE out of memory";
        case CTFEErrorKind.Overflow: return "integer overflow";
    }
}

/**
 * Format error message with call stack.
 */
string ctfeErrorMessageWithStack(NativeCTFEContext* ctx) {
    if (ctx is null) return "CTFE error (no context)";
    
    // Prefer inline stack from data section (faster, no FFI overhead)
    if (ctx.dataSection !is null && ctx.dataSection.stackReserved) {
        auto frames = ctx.dataSection.getInlineCallStack();
        if (frames.length > 0) {
            // Use inline stack for error message
            string result = ctfeErrorMessage(ctx.errorKind);
            result ~= formatInlineCallStack(ctx, frames);
            return result;
        }
    }
    
    // Fall back to D-side callStack
    return ctfeErrorMessage(ctx.errorKind) ~ ctx.formatCallStack();
}

/// Format inline call stack frames for error message
private string formatInlineCallStack(NativeCTFEContext* ctx, CallFrame[] frames) nothrow {
    import std.conv : to;
    import std.path : baseName;
    
    string result;
    try {
        // Show call stack
        if (frames.length > 0) {
            foreach_reverse (i, frame; frames) {
                string file = frame.fileName.length > 0 ? baseName(frame.fileName) : "<unknown>";
                string lineNum = to!string(frame.line);
                
                if (i == frames.length - 1) {
                    // Top of stack - show with source context if available
                    result ~= "\n --> " ~ file ~ ":" ~ lineNum;
                    string sourceLine = getSourceLine(frame.fileName, frame.line);
                    if (sourceLine.length > 0) {
                        result ~= "\n  |";
                        result ~= "\n" ~ padLeft(lineNum, 3) ~ " | " ~ sourceLine;
                    }
                    result ~= "\n  |";
                    result ~= "\nnote: in `" ~ frame.funcName ~ "()`";
                } else {
                    result ~= "\nnote: called from `" ~ frame.funcName ~ "()` at " ~ file ~ ":" ~ lineNum;
                }
            }
        }
    } catch (Exception) {}
    
    return result;
}

// ============================================================================
// Native Data Section
// ============================================================================

/**
 * Native data section for storing CTFE data (string literals, import() content).
 * 
 * Uses mmap for:
 * - Memory isolation from code
 * - Can be made read-only after initialization
 * - Stable pointers that persist for the lifetime of compilation
 */
// ============================================================================
// Inline Call Stack Constants
// ============================================================================
// Data section layout for inline stack tracking (no FFI overhead)
enum INLINE_STACK_DEPTH_OFFSET = 0;     // i32: current stack depth
enum INLINE_STACK_MAX_OFFSET = 4;       // i32: max depth (64)
enum INLINE_STACK_FRAMES_OFFSET = 8;    // InlineFrame[64] array
enum INLINE_FRAME_SIZE = 24;            // bytes per frame
enum INLINE_STACK_MAX_DEPTH = 64;       // maximum call depth
enum INLINE_STACK_RESERVED = INLINE_STACK_FRAMES_OFFSET + INLINE_STACK_MAX_DEPTH * INLINE_FRAME_SIZE;  // 1544 bytes

/// Inline call frame stored in data section (no GC, no FFI)
struct InlineFrame {
    uint nameOffset;    // offset of name string in data section
    uint nameLen;
    uint fileOffset;    // offset of file string in data section
    uint fileLen;
    uint line;
    uint column;
}

struct NativeDataSection {
    ubyte* base;
    size_t capacity;
    size_t used;
    bool stackReserved;  // whether inline call stack is reserved
    
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
    
    /// Reserve space for inline call stack at the start of data section
    /// Must be called before any other data is added
    void reserveInlineStack() {
        if (stackReserved) return;
        if (used > 0) {
            assert(false, "Must reserve inline stack before adding data");
        }
        
        // Initialize header
        *cast(uint*)(base + INLINE_STACK_DEPTH_OFFSET) = 0;  // depth = 0
        *cast(uint*)(base + INLINE_STACK_MAX_OFFSET) = INLINE_STACK_MAX_DEPTH;
        
        // Reserve space
        used = INLINE_STACK_RESERVED;
        stackReserved = true;
    }
    
    /// Get current inline stack depth
    uint getInlineStackDepth() nothrow {
        if (!stackReserved || base is null) return 0;
        return *cast(uint*)(base + INLINE_STACK_DEPTH_OFFSET);
    }
    
    /// Get inline frame at index (0 = bottom of stack)
    InlineFrame* getInlineFrame(uint index) nothrow {
        if (!stackReserved || base is null) return null;
        if (index >= INLINE_STACK_MAX_DEPTH) return null;
        return cast(InlineFrame*)(base + INLINE_STACK_FRAMES_OFFSET + index * INLINE_FRAME_SIZE);
    }
    
    /// Convert inline frame to CallFrame (resolves string offsets)
    CallFrame resolveInlineFrame(InlineFrame* frame) nothrow {
        CallFrame result;
        if (frame is null || base is null) return result;
        
        try {
            if (frame.nameLen > 0 && frame.nameOffset < used) {
                result.funcName = cast(string)(base + frame.nameOffset)[0..frame.nameLen];
            }
            if (frame.fileLen > 0 && frame.fileOffset < used) {
                result.fileName = cast(string)(base + frame.fileOffset)[0..frame.fileLen];
            }
            result.line = frame.line;
        } catch (Exception) {}
        
        return result;
    }
    
    /// Build CallFrame array from inline stack (for error reporting)
    CallFrame[] getInlineCallStack() nothrow {
        CallFrame[] result;
        if (!stackReserved || base is null) return result;
        
        try {
            uint depth = getInlineStackDepth();
            result.reserve(depth);
            for (uint i = 0; i < depth; i++) {
                auto frame = getInlineFrame(i);
                if (frame !is null) {
                    result ~= resolveInlineFrame(frame);
                }
            }
        } catch (Exception) {}
        
        return result;
    }
}

// ============================================================================
// CTFE Execution Context
// ============================================================================

/**
 * CTFE Execution Context - passed to all host functions.
 * 
 * This provides host functions with access to the execution environment
 * without requiring global state. All host functions receive this as
 * their first parameter.
 * 
 * Also contains error handling state for longjmp-based trap handling.
 */
/// Call frame info for stack traces
struct CallFrame {
    string funcName;
    string fileName;
    uint line;
}

/// Error location info (where the error actually occurred)
struct ErrorLocation {
    string fileName;
    uint line;
    uint column;
}

struct NativeCTFEContext {
    /// Data section for string literals, import() content, allocations
    NativeDataSection* dataSection;
    
    /// Error handling: longjmp target for trap recovery
    jmp_buf errorJump;
    
    /// Error kind if trap occurred
    CTFEErrorKind errorKind;
    
    /// Precise error location (expression-level)
    ErrorLocation errorLoc;
    
    /// Call stack for error reporting
    CallFrame[] callStack;
    
    /// Set error location (called by trap handler)
    void setErrorLocation(const(char)* filePtr, size_t fileLen, uint line, uint column) nothrow {
        try {
            errorLoc.fileName = cast(string)filePtr[0..fileLen];
            errorLoc.line = line;
            errorLoc.column = column;
        } catch (Exception) {}
    }
    
    /// Push a call frame onto the stack
    /// Args: namePtr, nameLen, filePtr, fileLen, line
    void pushCall(const(char)* namePtr, size_t nameLen,
                  const(char)* filePtr, size_t fileLen, uint line) nothrow {
        try {
            CallFrame frame;
            frame.funcName = cast(string)namePtr[0..nameLen];
            frame.fileName = cast(string)filePtr[0..fileLen];
            frame.line = line;
            callStack ~= frame;
        } catch (Exception) {}
    }
    
    /// Pop a call frame from the stack
    void popCall() nothrow {
        if (callStack.length > 0) {
            callStack = callStack[0..$-1];
        }
    }
    
    /// Format call stack for error message (rustc-style with source context)
    string formatCallStack() nothrow {
        import std.conv : to;
        import std.path : baseName;
        
        string result;
        try {
            // Show precise error location first (if available)
            if (errorLoc.line > 0) {
                string file = errorLoc.fileName.length > 0 ? baseName(errorLoc.fileName) : "<unknown>";
                string lineNum = to!string(errorLoc.line);
                string colNum = to!string(errorLoc.column);
                
                result ~= "\n --> " ~ file ~ ":" ~ lineNum ~ ":" ~ colNum;
                
                string sourceLine = getSourceLine(errorLoc.fileName, errorLoc.line);
                if (sourceLine.length > 0) {
                    result ~= "\n  |";
                    result ~= "\n" ~ padLeft(lineNum, 3) ~ " | " ~ sourceLine;
                    
                    // Add caret/underline at column position
                    if (errorLoc.column > 0) {
                        result ~= "\n  | " ~ spaces(errorLoc.column - 1) ~ "^^^";
                    }
                }
            }
            
            // Show call stack
            if (callStack.length > 0) {
                foreach_reverse (i, frame; callStack) {
                    string file = frame.fileName.length > 0 ? baseName(frame.fileName) : "<unknown>";
                    string lineNum = to!string(frame.line);
                    
                    // Skip innermost if we already showed errorLoc from same function
                    if (i == callStack.length - 1 && errorLoc.line > 0 && 
                        errorLoc.fileName == frame.fileName) {
                        result ~= "\n  |";
                        result ~= "\nnote: in `" ~ frame.funcName ~ "()`";
                        continue;
                    }
                    
                    result ~= "\nnote: called from `" ~ frame.funcName ~ "()` at " ~ file ~ ":" ~ lineNum;
                    
                    string sourceLine = getSourceLine(frame.fileName, frame.line);
                    if (sourceLine.length > 0) {
                        result ~= "\n  |";
                        result ~= "\n" ~ padLeft(lineNum, 3) ~ " | " ~ sourceLine;
                        result ~= "\n  |";
                    }
                }
            }
        } catch (Exception) {}
        return result;
    }
}

/// Generate a string of N spaces
private string spaces(size_t n) nothrow {
    if (n == 0) return "";
    try {
        char[] s = new char[n];
        s[] = ' ';
        return cast(string)s;
    } catch (Exception) {
        return "";
    }
}

// ============================================================================
// Source Line Cache (for error messages)
// ============================================================================

/// Cache of source file contents (file path -> lines)
private __gshared string[][string] sourceLineCache;

/// Get a specific line from a source file (1-indexed), returns empty on failure
string getSourceLine(string filePath, uint line) nothrow {
    if (filePath.length == 0 || line == 0) return "";
    
    try {
        // Check cache first
        if (auto linesPtr = filePath in sourceLineCache) {
            auto lines = *linesPtr;
            if (line <= lines.length) {
                return lines[line - 1];
            }
            return "";
        }
        
        // Read and cache the file
        import std.file : readText, exists;
        import std.string : splitLines;
        
        if (!exists(filePath)) return "";
        
        string content = readText(filePath);
        string[] lines = splitLines(content);
        sourceLineCache[filePath] = lines;
        
        if (line <= lines.length) {
            return lines[line - 1];
        }
    } catch (Exception) {}
    
    return "";
}

/// Left-pad a string to a minimum width
private string padLeft(string s, size_t width) nothrow {
    if (s.length >= width) return s;
    try {
        char[] padding = new char[width - s.length];
        padding[] = ' ';
        return cast(string)padding ~ s;
    } catch (Exception) {
        return s;
    }
}

// ============================================================================
// Host Function Table
// ============================================================================

/**
 * Function pointer type for host functions callable from native code.
 * 
 * Uses extern(C) calling convention for compatibility with native ABIs:
 * - First parameter is always the execution context
 * - Up to 3 additional arguments
 * - Return value is 64-bit
 */
alias HostFunctionPtr = extern(C) long function(NativeCTFEContext*, long, long, long) nothrow;

/**
 * Registry of host functions that native CTFE code can call.
 * 
 * Native code will:
 * 1. Look up function by name to get the table index
 * 2. Load the function pointer from the table
 * 3. Load execution context into first argument register
 * 4. Call function via indirect call
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
    
    /// Execution context pointer - passed to all host functions
    private NativeCTFEContext* context;
    
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
    void setContext(NativeCTFEContext* ctx) {
        context = ctx;
    }
    
    /// Get the address of the context pointer slot
    /// Generated code loads from this address to get the context
    ulong getContextSlotAddress() {
        return cast(ulong)&context;
    }
}

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
