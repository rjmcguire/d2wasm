/**
 * Target Configuration
 * 
 * Defines target-specific types for pointer sizes, offsets, etc.
 * Use typeof(Target.ptr) to get the pointer type for the current target.
 * 
 * Example:
 *   typeof(Target.ptr) slicePtr;      // 32-bit on WASM32, 64-bit on ARM64
 *   typeof(Target.offset) stackOff;   // Signed offset type
 */
module codegen.target;

/// WASM32 target - 32-bit pointers and sizes
struct WASM32Target {
    uint ptr;       /// 32-bit pointer/address
    uint size;      /// 32-bit size (like size_t)
    int offset;     /// 32-bit signed offset
}

/// WASM64 target - 64-bit pointers and sizes (future)
struct WASM64Target {
    ulong ptr;      /// 64-bit pointer/address
    ulong size;     /// 64-bit size
    long offset;    /// 64-bit signed offset
}

/// ARM64 native target - 64-bit pointers
struct ARM64Target {
    ulong ptr;      /// 64-bit pointer/address
    ulong size;     /// 64-bit size
    long offset;    /// 64-bit signed offset
}

// ============================================================================
// Current Target Selection
// ============================================================================

/// Current compilation target (change this one alias to retarget)
alias Target = WASM32Target;

// ============================================================================
// Derived Constants
// ============================================================================

/// Size of a pointer in bytes for the current target
enum PTR_SIZE = typeof(Target.ptr).sizeof;

/// Size of a pointer in bits for the current target  
enum PTR_BITS = PTR_SIZE * 8;

/// WASM type string for pointers ("i32" or "i64")
enum WASM_PTR_TYPE = PTR_SIZE == 4 ? "i32" : "i64";

/// WASM opcode base for pointer-sized loads (0x28 for i32.load, 0x29 for i64.load)
enum WASM_PTR_LOAD = PTR_SIZE == 4 ? 0x28 : 0x29;

/// WASM opcode for pointer-sized stores (0x36 for i32.store, 0x37 for i64.store)
enum WASM_PTR_STORE = PTR_SIZE == 4 ? 0x36 : 0x37;

/// WASM type byte for pointers (0x7F for i32, 0x7E for i64)
enum WASM_PTR_TYPE_BYTE = PTR_SIZE == 4 ? 0x7F : 0x7E;

// ============================================================================
// Layout Helpers
// ============================================================================

/**
 * Slice memory layout for a given target.
 * Use SliceLayout!Target.sizeof to get the correct size.
 */
struct SliceLayout(T) {
    typeof(T.ptr) ptr;
    uint length;
    uint capacity;
    
    /// Offset of the length field (uint for codegen compatibility)
    enum uint LENGTH_OFFSET = cast(uint)(typeof(T.ptr).sizeof);
    
    /// Offset of the capacity field (uint for codegen compatibility)
    enum uint CAPACITY_OFFSET = cast(uint)(typeof(T.ptr).sizeof + uint.sizeof);
}

/// Slice layout for the default target (WASM32)
alias WasmSliceLayout = SliceLayout!WASM32Target;

/// Slice layout for native ARM64 CTFE
alias NativeSliceLayout = SliceLayout!ARM64Target;

static assert(WasmSliceLayout.sizeof == 12, "WASM32 slice should be 12 bytes");
static assert(NativeSliceLayout.sizeof == 16, "ARM64 slice should be 16 bytes");
static assert(WasmSliceLayout.LENGTH_OFFSET == 4);
static assert(WasmSliceLayout.CAPACITY_OFFSET == 8);
static assert(NativeSliceLayout.LENGTH_OFFSET == 8);
static assert(NativeSliceLayout.CAPACITY_OFFSET == 12);

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    // Verify WASM32 target sizes
    static assert(PTR_SIZE == 4);
    static assert(PTR_BITS == 32);
    
    // Verify type sizes are as expected
    static assert(typeof(WASM32Target.ptr).sizeof == 4);
    static assert(typeof(ARM64Target.ptr).sizeof == 8);
    
    // Verify slice layouts
    static assert(WasmSliceLayout.sizeof == 12);
    static assert(WasmSliceLayout.LENGTH_OFFSET == 4);
    static assert(WasmSliceLayout.CAPACITY_OFFSET == 8);
    
    static assert(NativeSliceLayout.sizeof == 16);
    static assert(NativeSliceLayout.LENGTH_OFFSET == 8);
    static assert(NativeSliceLayout.CAPACITY_OFFSET == 12);
}
