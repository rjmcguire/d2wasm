module tests.test_type_marshal;

import codegen.type_marshal;
import codegen.target;
import std.math : isClose;

unittest {
    // --- Factory methods produce correct layout constants ---
    auto wasm = TypeReader.forWasm();
    assert(wasm.ptrSize == 4);
    assert(wasm.sliceLenOffset == WasmSliceLayout.LENGTH_OFFSET);
    assert(wasm.sliceCapOffset == WasmSliceLayout.CAPACITY_OFFSET);
    assert(wasm.sliceSize == WasmSliceLayout.sizeof);

    auto native = TypeReader.forNative();
    assert(native.ptrSize == 8);
    assert(native.sliceLenOffset == NativeSliceLayout.LENGTH_OFFSET);
    assert(native.sliceCapOffset == NativeSliceLayout.CAPACITY_OFFSET);
    assert(native.sliceSize == NativeSliceLayout.sizeof);
}

unittest {
    // --- readInt: 1-byte unsigned ---
    auto r = TypeReader.forWasm();
    assert(r.readInt([cast(ubyte)0], 1) == 0);
    assert(r.readInt([cast(ubyte)42], 1) == 42);
    assert(r.readInt([cast(ubyte)0xFF], 1) == 255);
}

unittest {
    // --- readInt: 4-byte signed little-endian ---
    auto r = TypeReader.forWasm();
    ubyte[4] ten = [10, 0, 0, 0];
    assert(r.readInt(ten[], 4) == 10);

    ubyte[4] neg1 = [0xFF, 0xFF, 0xFF, 0xFF];
    assert(r.readInt(neg1[], 4) == -1);

    ubyte[4] maxInt = [0xFF, 0xFF, 0xFF, 0x7F];
    assert(r.readInt(maxInt[], 4) == int.max);
}

unittest {
    // --- readUint: unsigned interpretation ---
    auto r = TypeReader.forWasm();
    ubyte[4] allOnes = [0xFF, 0xFF, 0xFF, 0xFF];
    assert(r.readUint(allOnes[], 4) == 0xFFFFFFFF);
}

unittest {
    // --- readFloat: f32 and f64 ---
    auto r = TypeReader.forWasm();

    // float 1.5 = 0x3FC00000
    ubyte[4] f15 = [0x00, 0x00, 0xC0, 0x3F];
    assert(isClose(r.readFloat(f15[], 4), 1.5));

    // double 2.5 = 0x4004000000000000
    ubyte[8] d25 = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x40];
    assert(isClose(r.readFloat(d25[], 8), 2.5));
}

unittest {
    // --- readPtr: 4-byte vs 8-byte ---
    auto wasm = TypeReader.forWasm();
    ubyte[4] wasmPtr = [100, 0, 0, 0];
    assert(wasm.readPtr(wasmPtr[]) == 100);

    auto native = TypeReader.forNative();
    ubyte[8] nativePtr = [0x00, 0x10, 0, 0, 0, 0, 0, 0];
    assert(native.readPtr(nativePtr[]) == 0x1000);

    // Large native pointer (above 4GB)
    ubyte[8] largePtr = [0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00];
    assert(native.readPtr(largePtr[]) == 0x0000_0006_0000_0000);
}

unittest {
    // --- readSlice: WASM 12-byte layout ---
    auto wasm = TypeReader.forWasm();
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
}

unittest {
    // --- readSlice: Native 16-byte layout ---
    auto native = TypeReader.forNative();
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
}

unittest {
    // --- elementSizeOf: all basic types ---
    import ast.nodes : BasicType, SourceLocation;
    auto loc = SourceLocation("test", 0, 0);

    assert(TypeReader.elementSizeOf(new BasicType(loc, BasicType.Kind.Bool)) == 1);
    assert(TypeReader.elementSizeOf(new BasicType(loc, BasicType.Kind.Int8)) == 1);
    assert(TypeReader.elementSizeOf(new BasicType(loc, BasicType.Kind.UInt8)) == 1);
    assert(TypeReader.elementSizeOf(new BasicType(loc, BasicType.Kind.Char)) == 1);
    assert(TypeReader.elementSizeOf(new BasicType(loc, BasicType.Kind.Int16)) == 2);
    assert(TypeReader.elementSizeOf(new BasicType(loc, BasicType.Kind.UInt16)) == 2);
    assert(TypeReader.elementSizeOf(new BasicType(loc, BasicType.Kind.Int32)) == 4);
    assert(TypeReader.elementSizeOf(new BasicType(loc, BasicType.Kind.UInt32)) == 4);
    assert(TypeReader.elementSizeOf(new BasicType(loc, BasicType.Kind.Float32)) == 4);
    assert(TypeReader.elementSizeOf(new BasicType(loc, BasicType.Kind.Int64)) == 8);
    assert(TypeReader.elementSizeOf(new BasicType(loc, BasicType.Kind.UInt64)) == 8);
    assert(TypeReader.elementSizeOf(new BasicType(loc, BasicType.Kind.Float64)) == 8);
}
