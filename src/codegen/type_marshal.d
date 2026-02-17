/**
 * Type Marshalling Layer
 *
 * Target-parameterized reader for extracting D values from raw memory buffers.
 * Used by CTFE to read results from both WASM and native backends without
 * hardcoding layout assumptions.
 *
 * Builds on: codegen.target (SliceLayout, WASM32Target, ARM64Target)
 */
module codegen.type_marshal;

import codegen.target;
import ast.nodes : Type, BasicType, ArrayType, StructDecl;
import std.format : format;

/// Result of reading a typed value from memory
struct MarshalledValue {
    enum Kind {
        integer,
        float_,
        slice,
        staticArray,
        struct_,
        raw
    }

    Kind kind;

    // Scalars
    long intVal;
    double floatVal;

    // Slice/array data
    ulong dataPtr;       // pointer to element data (target-native size)
    uint length;
    uint capacity;
    uint elementSize;
    ubyte[] elementData;  // raw element bytes (after following pointer)

    // Struct fields
    MarshalledValue[] fields;

    // Raw bytes (fallback)
    ubyte[] rawBytes;
}

/// Target-parameterized type reader
struct TypeReader {
    uint ptrSize;        // 4 for WASM32, 8 for ARM64
    uint slicePtrOffset; // always 0
    uint sliceLenOffset; // 4 for WASM32, 8 for ARM64
    uint sliceCapOffset; // 8 for WASM32, 12 for ARM64
    uint sliceSize;      // 12 for WASM32, 16 for ARM64

    static TypeReader forWasm() {
        return TypeReader(4, 0,
            WasmSliceLayout.LENGTH_OFFSET,
            WasmSliceLayout.CAPACITY_OFFSET,
            WasmSliceLayout.sizeof);
    }

    static TypeReader forNative() {
        return TypeReader(8, 0,
            NativeSliceLayout.LENGTH_OFFSET,
            NativeSliceLayout.CAPACITY_OFFSET,
            NativeSliceLayout.sizeof);
    }

    /// Read a signed integer of the given byte size from a buffer (little-endian).
    long readInt(const ubyte[] buf, uint size) {
        assert(buf.length >= size,
            format("readInt: buffer too small: %d < %d", buf.length, size));
        switch (size) {
            case 1:
                return buf[0];
            case 2:
                assert(buf.length >= 2, "readInt: buffer too small for 2-byte read");
                return *cast(const short*)buf.ptr;
            case 4:
                assert(buf.length >= 4, "readInt: buffer too small for 4-byte read");
                return *cast(const int*)buf.ptr;
            case 8:
                assert(buf.length >= 8, "readInt: buffer too small for 8-byte read");
                return *cast(const long*)buf.ptr;
            default:
                assert(0, format("readInt: unsupported size: %d", size));
        }
    }

    /// Read an unsigned integer of the given byte size from a buffer (little-endian).
    ulong readUint(const ubyte[] buf, uint size) {
        assert(buf.length >= size,
            format("readUint: buffer too small: %d < %d", buf.length, size));
        switch (size) {
            case 1:
                return buf[0];
            case 2:
                assert(buf.length >= 2, "readUint: buffer too small for 2-byte read");
                return *cast(const ushort*)buf.ptr;
            case 4:
                assert(buf.length >= 4, "readUint: buffer too small for 4-byte read");
                return *cast(const uint*)buf.ptr;
            case 8:
                assert(buf.length >= 8, "readUint: buffer too small for 8-byte read");
                return *cast(const ulong*)buf.ptr;
            default:
                assert(0, format("readUint: unsupported size: %d", size));
        }
    }

    /// Read a floating-point value from a buffer (little-endian).
    double readFloat(const ubyte[] buf, uint size) {
        assert(buf.length >= size,
            format("readFloat: buffer too small: %d < %d", buf.length, size));
        switch (size) {
            case 4:
                assert(buf.length >= 4, "readFloat: buffer too small for f32 read");
                return *cast(const float*)buf.ptr;
            case 8:
                assert(buf.length >= 8, "readFloat: buffer too small for f64 read");
                return *cast(const double*)buf.ptr;
            default:
                assert(0, format("readFloat: unsupported size: %d", size));
        }
    }

    /// Read a pointer value (target-native size) from a buffer.
    ulong readPtr(const ubyte[] buf) {
        assert(buf.length >= ptrSize,
            format("readPtr: buffer too small: %d < %d", buf.length, ptrSize));
        if (ptrSize == 4) {
            return *cast(const uint*)buf.ptr;
        } else {
            assert(ptrSize == 8, "readPtr: unexpected pointer size");
            return *cast(const ulong*)buf.ptr;
        }
    }

    /// Read a slice header {ptr, length, capacity} from a buffer.
    MarshalledValue readSlice(const ubyte[] buf) {
        assert(buf.length >= sliceSize,
            format("readSlice: buffer too small: %d < %d", buf.length, sliceSize));
        assert(buf.length >= sliceLenOffset + 4,
            format("readSlice: buffer too small for length field at offset %d", sliceLenOffset));
        assert(buf.length >= sliceCapOffset + 4,
            format("readSlice: buffer too small for capacity field at offset %d", sliceCapOffset));

        MarshalledValue v;
        v.kind = MarshalledValue.Kind.slice;
        v.dataPtr = readPtr(buf[slicePtrOffset .. $]);
        assert(sliceLenOffset + 4 <= buf.length, "readSlice: length field out of bounds");
        v.length = *cast(const uint*)&buf[sliceLenOffset];
        assert(sliceCapOffset + 4 <= buf.length, "readSlice: capacity field out of bounds");
        v.capacity = *cast(const uint*)&buf[sliceCapOffset];
        return v;
    }

    /// Read a typed value from a buffer, dispatching based on D type.
    MarshalledValue readValue(const ubyte[] buf, Type type) {
        if (auto basic = cast(BasicType)type) {
            return readBasicType(buf, basic);
        }
        if (auto arrType = cast(ArrayType)type) {
            if (arrType.arraySize is null) {
                // Dynamic array (slice)
                return readSlice(buf);
            } else {
                // Static array — read as raw bytes
                MarshalledValue v;
                v.kind = MarshalledValue.Kind.staticArray;
                uint elemSize = elementSizeOf(arrType.elementType);
                // TODO: get static array count from arraySize expression
                v.elementSize = elemSize;
                v.rawBytes = buf.dup;
                return v;
            }
        }
        if (auto sd = type.asStruct()) {
            return readStruct(buf, sd);
        }
        // Fallback: raw bytes
        MarshalledValue v;
        v.kind = MarshalledValue.Kind.raw;
        v.rawBytes = buf.dup;
        return v;
    }

    /// Read a struct value from a buffer using its field layout.
    MarshalledValue readStruct(const ubyte[] buf, StructDecl decl) {
        MarshalledValue v;
        v.kind = MarshalledValue.Kind.struct_;
        v.rawBytes = buf.dup;

        if (decl.fields) {
            foreach (field; decl.fields) {
                if (field.offset + field.size <= buf.length) {
                    auto fieldBuf = buf[field.offset .. field.offset + field.size];
                    v.fields ~= readValue(fieldBuf, field.type);
                }
            }
        }
        return v;
    }

    /// Compute the element size in bytes for a D type.
    /// Non-static: uses this.sliceSize for dynamic array element types.
    uint elementSizeOf(Type elementType) {
        if (auto basic = cast(BasicType)elementType) {
            switch (basic.kind) {
                case BasicType.Kind.Bool:
                case BasicType.Kind.Int8:
                case BasicType.Kind.UInt8:
                case BasicType.Kind.Char:
                    return 1;
                case BasicType.Kind.Int16:
                case BasicType.Kind.UInt16:
                    return 2;
                case BasicType.Kind.Int32:
                case BasicType.Kind.UInt32:
                case BasicType.Kind.Float32:
                    return 4;
                case BasicType.Kind.Int64:
                case BasicType.Kind.UInt64:
                case BasicType.Kind.Float64:
                    return 8;
                default:
                    return 4;
            }
        }
        if (auto sd = elementType.asStruct()) {
            return cast(uint)sd.aggregateSize_;
        }
        if (auto at = cast(ArrayType)elementType) {
            if (!at.isStaticArray)
                return sliceSize;  // dynamic array element = slice struct
        }
        return 4;  // default
    }

    private MarshalledValue readBasicType(const ubyte[] buf, BasicType basic) {
        MarshalledValue v;
        switch (basic.kind) {
            case BasicType.Kind.Bool:
            case BasicType.Kind.Int8:
            case BasicType.Kind.UInt8:
            case BasicType.Kind.Char:
                v.kind = MarshalledValue.Kind.integer;
                v.intVal = buf[0];
                return v;
            case BasicType.Kind.Int16:
            case BasicType.Kind.UInt16:
                v.kind = MarshalledValue.Kind.integer;
                v.intVal = readInt(buf, 2);
                return v;
            case BasicType.Kind.Int32:
            case BasicType.Kind.UInt32:
                v.kind = MarshalledValue.Kind.integer;
                v.intVal = readInt(buf, 4);
                return v;
            case BasicType.Kind.Int64:
            case BasicType.Kind.UInt64:
                v.kind = MarshalledValue.Kind.integer;
                v.intVal = readInt(buf, 8);
                return v;
            case BasicType.Kind.Float32:
                v.kind = MarshalledValue.Kind.float_;
                v.floatVal = readFloat(buf, 4);
                return v;
            case BasicType.Kind.Float64:
                v.kind = MarshalledValue.Kind.float_;
                v.floatVal = readFloat(buf, 8);
                return v;
            default:
                v.kind = MarshalledValue.Kind.integer;
                v.intVal = readInt(buf, 4);
                return v;
        }
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest {
    // --- WASM TypeReader ---
    auto wasm = TypeReader.forWasm();

    // Verify layout constants
    assert(wasm.ptrSize == 4);
    assert(wasm.sliceLenOffset == 4);
    assert(wasm.sliceCapOffset == 8);
    assert(wasm.sliceSize == 12);

    // --- Native TypeReader ---
    auto native = TypeReader.forNative();

    assert(native.ptrSize == 8);
    assert(native.sliceLenOffset == 8);
    assert(native.sliceCapOffset == 12);
    assert(native.sliceSize == 16);

    // --- readInt ---
    // 1-byte
    assert(wasm.readInt([cast(ubyte)42], 1) == 42);
    assert(wasm.readInt([cast(ubyte)0xFF], 1) == 255);

    // 4-byte little-endian: 10
    ubyte[4] le10 = [10, 0, 0, 0];
    assert(wasm.readInt(le10[], 4) == 10);

    // 4-byte little-endian: -1 (0xFFFFFFFF)
    ubyte[4] neg1 = [0xFF, 0xFF, 0xFF, 0xFF];
    assert(wasm.readInt(neg1[], 4) == -1);

    // 8-byte
    ubyte[8] le8 = [0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0];
    assert(wasm.readInt(le8[], 8) == 0x12345678);

    // --- readUint ---
    assert(wasm.readUint(neg1[], 4) == 0xFFFFFFFF);

    // --- readFloat ---
    // float 1.5 = 0x3FC00000
    ubyte[4] f15 = [0x00, 0x00, 0xC0, 0x3F];
    import std.math : isClose;
    assert(isClose(wasm.readFloat(f15[], 4), 1.5));

    // double 2.5 = 0x4004000000000000
    ubyte[8] d25 = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x40];
    assert(isClose(wasm.readFloat(d25[], 8), 2.5));

    // --- readPtr ---
    ubyte[4] wasmPtr = [100, 0, 0, 0];
    assert(wasm.readPtr(wasmPtr[]) == 100);

    ubyte[8] nativePtr = [0x00, 0x10, 0, 0, 0, 0, 0, 0];
    assert(native.readPtr(nativePtr[]) == 0x1000);

    // --- readSlice (WASM) ---
    // WASM slice: ptr=100, len=3, cap=5
    ubyte[12] wasmSlice = [
        100, 0, 0, 0,   // ptr = 100
          3, 0, 0, 0,   // len = 3
          5, 0, 0, 0,   // cap = 5
    ];
    auto sv = wasm.readSlice(wasmSlice[]);
    assert(sv.kind == MarshalledValue.Kind.slice);
    assert(sv.dataPtr == 100);
    assert(sv.length == 3);
    assert(sv.capacity == 5);

    // --- readSlice (Native) ---
    // Native slice: ptr=0x1000, len=3, cap=5
    ubyte[16] nativeSlice = [
        0x00, 0x10, 0, 0, 0, 0, 0, 0,   // ptr = 0x1000
           3,    0, 0, 0,                 // len = 3
           5,    0, 0, 0,                 // cap = 5
    ];
    auto nv = native.readSlice(nativeSlice[]);
    assert(nv.kind == MarshalledValue.Kind.slice);
    assert(nv.dataPtr == 0x1000);
    assert(nv.length == 3);
    assert(nv.capacity == 5);

    // --- elementSizeOf (instance method, uses target sliceSize) ---
    import ast.nodes : SourceLocation;
    auto loc = SourceLocation("test", 0, 0);
    assert(wasm.elementSizeOf(new BasicType(loc, BasicType.Kind.Bool)) == 1);
    assert(wasm.elementSizeOf(new BasicType(loc, BasicType.Kind.UInt8)) == 1);
    assert(wasm.elementSizeOf(new BasicType(loc, BasicType.Kind.Int16)) == 2);
    assert(wasm.elementSizeOf(new BasicType(loc, BasicType.Kind.Int32)) == 4);
    assert(wasm.elementSizeOf(new BasicType(loc, BasicType.Kind.Float32)) == 4);
    assert(wasm.elementSizeOf(new BasicType(loc, BasicType.Kind.Float64)) == 8);
    assert(wasm.elementSizeOf(new BasicType(loc, BasicType.Kind.Int64)) == 8);
    // Dynamic array element = slice struct sized by target
    auto ubyteType = new BasicType(loc, BasicType.Kind.UInt8);
    assert(wasm.elementSizeOf(new ArrayType(loc, ubyteType)) == WasmSliceLayout.sizeof);
    assert(native.elementSizeOf(new ArrayType(loc, ubyteType)) == NativeSliceLayout.sizeof);
}
