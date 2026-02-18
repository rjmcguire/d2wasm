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
// Vtable Pointer Packing
// ============================================================================

/**
 * Vtable/itable pointer packing constants.
 * 
 * Packed pointer design:
 *   vtable_ptr = (typeId << TYPE_ID_SHIFT) | tableBase
 * 
 * Extract:
 *   typeId = vtable_ptr >> TYPE_ID_SHIFT
 *   tableBase = vtable_ptr & TABLE_BASE_MASK
 * 
 * For 32-bit targets: 16-bit typeId (65535 types), 16-bit tableBase
 * For 64-bit targets: 32-bit typeId, 32-bit tableBase (future)
 */
struct VtablePacking(T) {
    static if (typeof(T.ptr).sizeof == 4) {
        // 32-bit pointer: 16/16 split
        enum uint TYPE_ID_SHIFT = 16;
        enum uint TABLE_BASE_MASK = 0xFFFF;
        enum uint TYPE_ID_MASK = 0xFFFF0000;
        enum uint MAX_TYPE_ID = 0xFFFF;
        enum uint MAX_TABLE_BASE = 0xFFFF;
    } else {
        // 64-bit pointer: 32/32 split
        enum uint TYPE_ID_SHIFT = 32;
        enum ulong TABLE_BASE_MASK = 0xFFFFFFFF;
        enum ulong TYPE_ID_MASK = 0xFFFFFFFF00000000;
        enum uint MAX_TYPE_ID = 0xFFFFFFFF;
        enum uint MAX_TABLE_BASE = 0xFFFFFFFF;
    }
    
    /// Pack typeId and tableBase into a pointer-sized value
    static typeof(T.ptr) pack(uint typeId, uint tableBase) {
        return cast(typeof(T.ptr))((cast(typeof(T.ptr))typeId << TYPE_ID_SHIFT) | tableBase);
    }
    
    /// Extract tableBase from packed pointer
    static uint unpackTableBase(typeof(T.ptr) packed) {
        return cast(uint)(packed & TABLE_BASE_MASK);
    }
    
    /// Extract typeId from packed pointer  
    static uint unpackTypeId(typeof(T.ptr) packed) {
        return cast(uint)(packed >> TYPE_ID_SHIFT);
    }
}

/// Vtable packing for WASM32 target
alias WasmVtablePacking = VtablePacking!WASM32Target;

/// Vtable packing for ARM64 native target (uses same 16/16 for WASM compat)
alias NativeVtablePacking = VtablePacking!WASM32Target;  // WASM output is always 32-bit

static assert(WasmVtablePacking.TYPE_ID_SHIFT == 16);
static assert(WasmVtablePacking.TABLE_BASE_MASK == 0xFFFF);

// ============================================================================
// Layout Helpers
// ============================================================================

/**
 * Runtime-computed slice layout info.
 * Slice = {pointer, uint length, uint capacity}.
 * Total size = ptrSize + 4 + 4, offsets derived from ptrSize.
 */
struct SliceInfo {
    uint ptrSize;       /// 4 for WASM32, 8 for ARM64

    @property uint totalSize() const { return ptrSize + 8; }
    @property uint ptrOffset() const { return 0; }
    @property uint lengthOffset() const { return ptrSize; }
    @property uint capacityOffset() const { return ptrSize + 4; }
}

/// Default slice info (WASM32 — 4-byte pointers)
__gshared SliceInfo sliceInfo = SliceInfo(4);

/// Legacy template — kept only for backward compatibility in tests.
/// Prefer sliceInfo for all new code.
struct SliceLayout(T) {
    typeof(T.ptr) ptr;
    uint length;
    uint capacity;

    enum uint LENGTH_OFFSET = cast(uint)(typeof(T.ptr).sizeof);
    enum uint CAPACITY_OFFSET = cast(uint)(typeof(T.ptr).sizeof + uint.sizeof);
}

alias WasmSliceLayout = SliceLayout!WASM32Target;
alias NativeSliceLayout = SliceLayout!ARM64Target;

static assert(WasmSliceLayout.sizeof == 12, "WASM32 slice should be 12 bytes");
static assert(NativeSliceLayout.sizeof == 16, "ARM64 slice should be 16 bytes");

// Verify SliceInfo matches the template-derived values
static assert(SliceInfo(4).totalSize == WasmSliceLayout.sizeof);
static assert(SliceInfo(4).lengthOffset == WasmSliceLayout.LENGTH_OFFSET);
static assert(SliceInfo(4).capacityOffset == WasmSliceLayout.CAPACITY_OFFSET);
static assert(SliceInfo(8).totalSize == NativeSliceLayout.sizeof);
static assert(SliceInfo(8).lengthOffset == NativeSliceLayout.LENGTH_OFFSET);
static assert(SliceInfo(8).capacityOffset == NativeSliceLayout.CAPACITY_OFFSET);

/**
 * Interface fat pointer layout: {obj_ptr, itable_ptr}
 * Used for interface dispatch - NOT a slice!
 */
struct FatPointerLayout(T) {
    typeof(T.ptr) obj_ptr;
    typeof(T.ptr) itable_ptr;
    
    /// Offset of the itable_ptr field
    enum uint ITABLE_OFFSET = cast(uint)(typeof(T.ptr).sizeof);
}

/// Fat pointer layout for WASM32
alias WasmFatPointerLayout = FatPointerLayout!WASM32Target;

static assert(WasmFatPointerLayout.sizeof == 8, "WASM32 fat pointer should be 8 bytes");
static assert(WasmFatPointerLayout.ITABLE_OFFSET == 4);

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

    // Verify SliceInfo computed properties
    enum wasm = SliceInfo(4);
    static assert(wasm.totalSize == 12);
    static assert(wasm.ptrOffset == 0);
    static assert(wasm.lengthOffset == 4);
    static assert(wasm.capacityOffset == 8);

    enum native = SliceInfo(8);
    static assert(native.totalSize == 16);
    static assert(native.ptrOffset == 0);
    static assert(native.lengthOffset == 8);
    static assert(native.capacityOffset == 12);
}
