/**
 * Manifest constant cache — persists CTFE results across compilations.
 *
 * Stores evaluated manifest constant values (integers, floats, strings,
 * arrays) so they can be restored on the next compile without re-running
 * CTFE, provided the dep graph shows no transitive source changes.
 *
 * Binary format follows the same pattern as DeclDependencyGraph:
 *   magic + version + string table + entries + CRC32 checksum.
 */
module cache.manifest_cache;

import std.array : appender, Appender;
import std.digest.crc : crc32Of;
import semantic.symbol_table : SymbolTable;

/// Type discriminant for cached manifest values.
enum ManifestTypeKind : ubyte {
    int32 = 0,
    float64 = 1,
    string_ = 2,
    array = 3,
    nestedArray = 4,
    bool_ = 5,
    char_ = 6,
    int64 = 7,
}

/// One cached manifest constant value.
struct ManifestCacheEntry {
    string name;              /// manifest constant name
    // Value storage (mirrors ManifestConstantDecl fields):
    long intValue;
    double floatValue;
    string stringValue;
    ubyte[] arrayBytes;
    uint elementSize;
    ubyte[][] nestedElements;
    uint innerElementSize;
    ManifestTypeKind typeKind;
}

/**
 * Collection of cached manifest constant values for one module.
 */
class ManifestCache {

    ManifestCacheEntry[] entries;

    /// Magic bytes for manifest cache binary format
    private static immutable ubyte[4] MAGIC = ['D', '2', 'M', 'C'];
    private static immutable uint FORMAT_VERSION = 1;

    /**
     * Serialize cache to binary format.
     *
     * Layout:
     *   [4]  magic: 'D','2','M','C'
     *   [4]  version: u32 LE = 1
     *   --- string table ---
     *   [4]  string_count: u32
     *   for each string: [4] len + [N] bytes
     *   --- entries ---
     *   [4]  entry_count: u32
     *   for each entry:
     *     [4] name_idx
     *     [1] typeKind
     *     [8] intValue (i64 LE)
     *     [8] floatValue (f64 LE, raw bits)
     *     [4] stringValue_idx
     *     [4] arrayBytes_len + [N] arrayBytes
     *     [4] elementSize
     *     [4] innerElementSize
     *     [4] nestedElements_count
     *     for each nested: [4] len + [N] bytes
     *   --- checksum ---
     *   [4]  CRC32 of all bytes above
     */
    ubyte[] serialize() {
        auto buf = appender!(ubyte[]);

        // -- Header --
        buf.put(MAGIC[]);
        putU32(buf, FORMAT_VERSION);

        // -- Build string table --
        uint[string] stringIndex;
        string[] stringTable;

        uint intern(string s) {
            if (auto p = s in stringIndex)
                return *p;
            uint idx = cast(uint) stringTable.length;
            stringIndex[s] = idx;
            stringTable ~= s;
            return idx;
        }

        // Pre-intern all strings
        uint[][] entryStringIds = new uint[][](entries.length);
        foreach (i, ref e; entries) {
            entryStringIds[i] = [intern(e.name), intern(e.stringValue)];
        }

        // Write string table
        putU32(buf, cast(uint) stringTable.length);
        foreach (s; stringTable) {
            putU32(buf, cast(uint) s.length);
            buf.put(cast(const(ubyte)[]) s);
        }

        // -- Entries --
        putU32(buf, cast(uint) entries.length);
        foreach (i, ref e; entries) {
            putU32(buf, entryStringIds[i][0]); // name_idx
            buf.put(cast(ubyte) e.typeKind);
            putI64(buf, e.intValue);
            putF64(buf, e.floatValue);
            putU32(buf, entryStringIds[i][1]); // stringValue_idx

            // arrayBytes
            putU32(buf, cast(uint) e.arrayBytes.length);
            if (e.arrayBytes.length > 0)
                buf.put(e.arrayBytes);

            putU32(buf, e.elementSize);
            putU32(buf, e.innerElementSize);

            // nestedElements
            putU32(buf, cast(uint) e.nestedElements.length);
            foreach (ref nested; e.nestedElements) {
                putU32(buf, cast(uint) nested.length);
                if (nested.length > 0)
                    buf.put(nested);
            }
        }

        // -- CRC32 checksum --
        auto data = buf.data;
        auto crc = crc32Of(data);
        buf.put(crc[]);

        return buf.data;
    }

    /**
     * Deserialize cache from binary format.
     * Returns null on corruption, version mismatch, or truncation.
     */
    static ManifestCache deserialize(const(ubyte)[] data) {
        // Minimum: magic(4) + version(4) + string_count(4) + entry_count(4) + crc(4) = 20
        if (data.length < 20)
            return null;

        // Verify CRC32 first
        auto contentData = data[0 .. $ - 4];
        auto storedCrc = data[$ - 4 .. $];
        if (storedCrc != crc32Of(contentData))
            return null;

        size_t pos = 0;

        // Magic
        if (data[0 .. 4] != MAGIC)
            return null;
        pos += 4;

        // Version
        uint ver = getU32(data, pos);
        pos += 4;
        if (ver != FORMAT_VERSION)
            return null;

        // -- String table --
        if (pos + 4 > contentData.length) return null;
        uint stringCount = getU32(data, pos);
        pos += 4;

        string[] stringTable = new string[](stringCount);
        foreach (i; 0 .. stringCount) {
            if (pos + 4 > contentData.length) return null;
            uint slen = getU32(data, pos);
            pos += 4;
            if (pos + slen > contentData.length) return null;
            stringTable[i] = cast(string) data[pos .. pos + slen].dup;
            pos += slen;
        }

        // -- Entries --
        if (pos + 4 > contentData.length) return null;
        uint entryCount = getU32(data, pos);
        pos += 4;

        auto cache = new ManifestCache();

        foreach (_; 0 .. entryCount) {
            ManifestCacheEntry e;

            // name_idx (4) + typeKind (1) + intValue (8) + floatValue (8) +
            // stringValue_idx (4) + arrayBytes_len (4) = 29 minimum
            if (pos + 29 > contentData.length) return null;

            uint nameIdx = getU32(data, pos); pos += 4;
            if (nameIdx >= stringCount) return null;
            e.name = stringTable[nameIdx];

            ubyte tk = data[pos]; pos += 1;
            if (tk > ManifestTypeKind.max) return null;
            e.typeKind = cast(ManifestTypeKind) tk;

            e.intValue = getI64(data, pos); pos += 8;
            e.floatValue = getF64(data, pos); pos += 8;

            uint strIdx = getU32(data, pos); pos += 4;
            if (strIdx >= stringCount) return null;
            e.stringValue = stringTable[strIdx];

            // arrayBytes
            uint abLen = getU32(data, pos); pos += 4;
            if (pos + abLen > contentData.length) return null;
            if (abLen > 0)
                e.arrayBytes = data[pos .. pos + abLen].dup;
            pos += abLen;

            // elementSize + innerElementSize + nestedElements_count = 12
            if (pos + 12 > contentData.length) return null;
            e.elementSize = getU32(data, pos); pos += 4;
            e.innerElementSize = getU32(data, pos); pos += 4;

            uint nestedCount = getU32(data, pos); pos += 4;
            if (nestedCount > 0) {
                e.nestedElements = new ubyte[][](nestedCount);
                foreach (ni; 0 .. nestedCount) {
                    if (pos + 4 > contentData.length) return null;
                    uint nLen = getU32(data, pos); pos += 4;
                    if (pos + nLen > contentData.length) return null;
                    if (nLen > 0)
                        e.nestedElements[ni] = data[pos .. pos + nLen].dup;
                    pos += nLen;
                }
            }

            cache.entries ~= e;
        }

        return cache;
    }

    /**
     * Save cache to file atomically (write to .tmp, then rename).
     */
    void saveToFile(string path) {
        import std.file : write, exists, rename, remove, mkdirRecurse;
        import std.path : dirName;

        auto dir = dirName(path);
        if (dir.length > 0 && !exists(dir))
            mkdirRecurse(dir);

        auto data = serialize();
        string tmpPath = path ~ ".tmp";
        try {
            write(tmpPath, data);
            if (exists(path))
                remove(path);
            rename(tmpPath, path);
        } catch (Exception) {
            // Clean up temp file on failure
            if (exists(tmpPath)) {
                try { remove(tmpPath); } catch (Exception) {}
            }
        }
    }

    /**
     * Load cache from file. Returns null if file missing or corrupt.
     */
    static ManifestCache loadFromFile(string path) {
        import std.file : exists, read;

        if (!exists(path))
            return null;

        ubyte[] data;
        try {
            data = cast(ubyte[]) read(path);
        } catch (Exception) {
            return null;
        }

        return deserialize(data);
    }
}

// ------------------------------------------------------------------
//  Initializer declaration stamping (for cache-restored manifests)
// ------------------------------------------------------------------

import ast.nodes;
import ast.expressions;

/**
 * Walk a manifest's initializer expression tree and stamp
 * ident.declaration for call targets, replicating what the CTFE
 * evaluator normally does.
 *
 * This is critical for cache-restored manifests: the graph builder
 * needs ident.declaration set on CallExpression targets to record
 * CONST → ctfeHelper edges. Without this, the dep graph loses edges
 * on cache-hit compiles.
 */
void stampInitializerDeclarations(Expression expr, SymbolTable symbolTable) {
    import semantic.symbol_table : SymbolKind;

    if (expr is null || symbolTable is null)
        return;

    if (auto call = cast(CallExpression) expr) {
        // Stamp the call target if it's a direct identifier
        if (auto ident = cast(IdentifierExpression) call.function_) {
            if (ident.declaration is null) {
                auto sym = symbolTable.lookupGlobalSymbol(ident.name);
                if (sym !is null && sym.kind == SymbolKind.Function)
                    ident.declaration = sym.declaration;
            }
        }
        // Recurse into callee (for member expressions etc.)
        stampInitializerDeclarations(call.function_, symbolTable);
        // Recurse into arguments
        foreach (arg; call.arguments)
            stampInitializerDeclarations(arg, symbolTable);
    }
    else if (auto bin = cast(BinaryExpression) expr) {
        stampInitializerDeclarations(bin.left, symbolTable);
        stampInitializerDeclarations(bin.right, symbolTable);
        if (bin.loweredCall !is null)
            stampInitializerDeclarations(bin.loweredCall, symbolTable);
    }
    else if (auto unary = cast(UnaryExpression) expr) {
        stampInitializerDeclarations(unary.operand, symbolTable);
        if (unary.loweredCall !is null)
            stampInitializerDeclarations(unary.loweredCall, symbolTable);
    }
    else if (auto cast_ = cast(CastExpression) expr) {
        stampInitializerDeclarations(cast_.expression, symbolTable);
    }
    else if (auto member = cast(MemberExpression) expr) {
        stampInitializerDeclarations(member.object, symbolTable);
    }
    else if (auto index = cast(IndexExpression) expr) {
        stampInitializerDeclarations(index.array, symbolTable);
        stampInitializerDeclarations(index.index, symbolTable);
    }
    // LiteralExpression, IdentifierExpression (non-call), etc. — no action needed
}

// ------------------------------------------------------------------
//  Build cache from AST
// ------------------------------------------------------------------

/**
 * Walk an AST and collect all completed manifest constants into a cache.
 */
ManifestCache buildManifestCache(Declaration[] ast) {
    auto cache = new ManifestCache();

    foreach (decl; ast) {
        auto manifest = cast(ManifestConstantDecl) decl;
        if (manifest is null || !manifest.ctfeComplete)
            continue;

        ManifestCacheEntry e;
        e.name = manifest.name;
        e.intValue = manifest.ctfeValue;
        e.floatValue = manifest.ctfeFloatValue;
        e.stringValue = manifest.ctfeStringValue;
        e.arrayBytes = manifest.ctfeArrayBytes;
        e.elementSize = manifest.ctfeElementSize;
        e.innerElementSize = manifest.ctfeInnerElementSize;

        if (manifest.ctfeNestedElements !is null)
            e.nestedElements = manifest.ctfeNestedElements.dup;

        // Determine typeKind
        if (manifest.isNestedArrayType)
            e.typeKind = ManifestTypeKind.nestedArray;
        else if (manifest.isArrayType)
            e.typeKind = ManifestTypeKind.array;
        else if (manifest.isStringType)
            e.typeKind = ManifestTypeKind.string_;
        else if (manifest.isFloatType)
            e.typeKind = ManifestTypeKind.float64;
        else {
            // Integral: distinguish bool, char, int32, int64 via inferredType
            auto bt = manifest.inferredType !is null
                ? cast(BasicType) manifest.inferredType : null;
            if (bt !is null && bt.kind == BasicType.Kind.Bool)
                e.typeKind = ManifestTypeKind.bool_;
            else if (bt !is null && bt.kind == BasicType.Kind.Char)
                e.typeKind = ManifestTypeKind.char_;
            else if (bt !is null && (bt.kind == BasicType.Kind.Int64 || bt.kind == BasicType.Kind.UInt64))
                e.typeKind = ManifestTypeKind.int64;
            else
                e.typeKind = ManifestTypeKind.int32;
        }

        cache.entries ~= e;
    }

    return cache;
}

/**
 * Restore a manifest constant's value from a cache entry.
 * Sets all ctfe* fields and marks ctfeComplete = true.
 */
void restoreManifest(ManifestConstantDecl manifest, ref const ManifestCacheEntry entry) {
    manifest.ctfeValue = entry.intValue;
    manifest.ctfeFloatValue = entry.floatValue;
    manifest.ctfeStringValue = entry.stringValue;
    manifest.ctfeArrayBytes = cast(ubyte[]) entry.arrayBytes;
    manifest.ctfeElementSize = entry.elementSize;
    manifest.ctfeInnerElementSize = entry.innerElementSize;

    if (entry.nestedElements.length > 0) {
        manifest.ctfeNestedElements = new ubyte[][](entry.nestedElements.length);
        foreach (i, ref ne; entry.nestedElements)
            manifest.ctfeNestedElements[i] = cast(ubyte[]) ne;
    }

    // Set type discriminant flags
    final switch (entry.typeKind) {
        case ManifestTypeKind.int32:
            manifest.inferredType = new BasicType(SourceLocation.init, BasicType.Kind.Int32);
            break;
        case ManifestTypeKind.int64:
            manifest.inferredType = new BasicType(SourceLocation.init, BasicType.Kind.Int64);
            break;
        case ManifestTypeKind.float64:
            manifest.isFloatType = true;
            manifest.inferredType = new BasicType(SourceLocation.init, BasicType.Kind.Float64);
            break;
        case ManifestTypeKind.string_:
            manifest.isStringType = true;
            manifest.inferredType = new ArrayType(SourceLocation.init,
                new BasicType(SourceLocation.init, BasicType.Kind.UInt8), null);
            break;
        case ManifestTypeKind.array:
            manifest.isArrayType = true;
            // Infer element type from element size
            manifest.inferredType = inferArrayType(entry.elementSize);
            break;
        case ManifestTypeKind.nestedArray:
            manifest.isNestedArrayType = true;
            manifest.isArrayType = true;
            // Nested array: array of arrays
            manifest.inferredType = inferNestedArrayType(entry.innerElementSize);
            break;
        case ManifestTypeKind.bool_:
            manifest.inferredType = new BasicType(SourceLocation.init, BasicType.Kind.Bool);
            break;
        case ManifestTypeKind.char_:
            manifest.inferredType = new BasicType(SourceLocation.init, BasicType.Kind.Char);
            break;
    }

    manifest.ctfeComplete = true;
}

/// Infer an ArrayType from element size.
private Type inferArrayType(uint elemSize) {
    BasicType.Kind elemKind;
    switch (elemSize) {
        case 1: elemKind = BasicType.Kind.UInt8; break;
        case 2: elemKind = BasicType.Kind.Int16; break;
        case 4: elemKind = BasicType.Kind.Int32; break;
        case 8: elemKind = BasicType.Kind.Int64; break;
        default: elemKind = BasicType.Kind.UInt8; break;
    }
    return new ArrayType(SourceLocation.init,
        new BasicType(SourceLocation.init, elemKind), null);
}

/// Infer a nested ArrayType (T[][]) from inner element size.
private Type inferNestedArrayType(uint innerElemSize) {
    auto innerArray = inferArrayType(innerElemSize);
    return new ArrayType(SourceLocation.init, innerArray, null);
}

// ------------------------------------------------------------------
//  Private binary encoding helpers
// ------------------------------------------------------------------

/// Write a u32 in little-endian
private void putU32(ref Appender!(ubyte[]) buf, uint value) {
    buf.put(cast(ubyte)(value & 0xFF));
    buf.put(cast(ubyte)((value >> 8) & 0xFF));
    buf.put(cast(ubyte)((value >> 16) & 0xFF));
    buf.put(cast(ubyte)((value >> 24) & 0xFF));
}

/// Read a u32 in little-endian
private uint getU32(const(ubyte)[] data, size_t pos) {
    return cast(uint) data[pos]
         | (cast(uint) data[pos + 1] << 8)
         | (cast(uint) data[pos + 2] << 16)
         | (cast(uint) data[pos + 3] << 24);
}

/// Write an i64 in little-endian
private void putI64(ref Appender!(ubyte[]) buf, long value) {
    ulong v = cast(ulong) value;
    foreach (i; 0 .. 8)
        buf.put(cast(ubyte)((v >> (i * 8)) & 0xFF));
}

/// Read an i64 in little-endian
private long getI64(const(ubyte)[] data, size_t pos) {
    ulong v = 0;
    foreach (i; 0 .. 8)
        v |= cast(ulong) data[pos + i] << (i * 8);
    return cast(long) v;
}

/// Write an f64 as raw 8 bytes (IEEE 754 little-endian)
private void putF64(ref Appender!(ubyte[]) buf, double value) {
    auto raw = *cast(ulong*)&value;
    putI64(buf, cast(long) raw);
}

/// Read an f64 from raw 8 bytes
private double getF64(const(ubyte)[] data, size_t pos) {
    long raw = getI64(data, pos);
    return *cast(double*)&raw;
}

// ------------------------------------------------------------------
//  Unit tests
// ------------------------------------------------------------------
unittest {
    import std.stdio : writefln;
    import std.math : isNaN;

    // Test 1: Round-trip empty cache
    {
        auto c = new ManifestCache();
        auto data = c.serialize();
        auto c2 = ManifestCache.deserialize(data);
        assert(c2 !is null, "Empty cache round-trip failed");
        assert(c2.entries.length == 0);
        writefln("  ok: empty manifest cache round-trip");
    }

    // Test 2: Round-trip with entries of each type
    {
        auto c = new ManifestCache();

        // Int entry
        ManifestCacheEntry intE;
        intE.name = "INT_CONST";
        intE.typeKind = ManifestTypeKind.int32;
        intE.intValue = 42;
        c.entries ~= intE;

        // Float entry
        ManifestCacheEntry floatE;
        floatE.name = "PI";
        floatE.typeKind = ManifestTypeKind.float64;
        floatE.floatValue = 3.14159;
        c.entries ~= floatE;

        // String entry
        ManifestCacheEntry strE;
        strE.name = "GREETING";
        strE.typeKind = ManifestTypeKind.string_;
        strE.stringValue = "hello world";
        c.entries ~= strE;

        // Array entry
        ManifestCacheEntry arrE;
        arrE.name = "DATA";
        arrE.typeKind = ManifestTypeKind.array;
        arrE.arrayBytes = [1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0];
        arrE.elementSize = 4;
        c.entries ~= arrE;

        // Bool entry
        ManifestCacheEntry boolE;
        boolE.name = "FLAG";
        boolE.typeKind = ManifestTypeKind.bool_;
        boolE.intValue = 1;
        c.entries ~= boolE;

        auto data = c.serialize();
        auto c2 = ManifestCache.deserialize(data);

        assert(c2 !is null, "Non-empty cache round-trip failed");
        assert(c2.entries.length == 5, "Entry count mismatch");

        assert(c2.entries[0].name == "INT_CONST");
        assert(c2.entries[0].typeKind == ManifestTypeKind.int32);
        assert(c2.entries[0].intValue == 42);

        assert(c2.entries[1].name == "PI");
        assert(c2.entries[1].typeKind == ManifestTypeKind.float64);
        assert(c2.entries[1].floatValue == 3.14159);

        assert(c2.entries[2].name == "GREETING");
        assert(c2.entries[2].stringValue == "hello world");

        assert(c2.entries[3].name == "DATA");
        assert(c2.entries[3].arrayBytes == [1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0]);
        assert(c2.entries[3].elementSize == 4);

        assert(c2.entries[4].name == "FLAG");
        assert(c2.entries[4].typeKind == ManifestTypeKind.bool_);
        assert(c2.entries[4].intValue == 1);

        writefln("  ok: manifest cache round-trip with entries");
    }

    // Test 3: Corruption detection
    {
        auto c = new ManifestCache();
        ManifestCacheEntry e;
        e.name = "X";
        e.typeKind = ManifestTypeKind.int32;
        e.intValue = 99;
        c.entries ~= e;

        auto data = c.serialize();

        // Corrupt a byte
        auto corrupted = data.dup;
        corrupted[12] ^= 0xFF;
        assert(ManifestCache.deserialize(corrupted) is null, "Should detect corruption");

        // Truncated data
        assert(ManifestCache.deserialize(data[0 .. 10]) is null, "Should reject truncated data");

        // Wrong magic
        auto badMagic = data.dup;
        badMagic[0] = 'X';
        assert(ManifestCache.deserialize(badMagic) is null, "Should reject bad magic");

        writefln("  ok: manifest cache corruption detection");
    }

    // Test 4: File I/O round-trip
    {
        import std.file : tempDir, exists, remove, mkdirRecurse, rmdirRecurse;
        import std.path : buildPath;

        string testPath = buildPath(tempDir(), "d2wasm_manifest_test", "test_cache.bin");

        auto c = new ManifestCache();
        ManifestCacheEntry e;
        e.name = "TEST";
        e.typeKind = ManifestTypeKind.int32;
        e.intValue = 123;
        c.entries ~= e;

        c.saveToFile(testPath);
        assert(exists(testPath), "File should exist after save");

        auto c2 = ManifestCache.loadFromFile(testPath);
        assert(c2 !is null, "Should load from file");
        assert(c2.entries.length == 1);
        assert(c2.entries[0].name == "TEST");
        assert(c2.entries[0].intValue == 123);

        // Clean up
        try {
            remove(testPath);
            rmdirRecurse(buildPath(tempDir(), "d2wasm_manifest_test"));
        } catch (Exception) {}

        // Missing file returns null
        assert(ManifestCache.loadFromFile("/nonexistent/path/cache.bin") is null);

        writefln("  ok: manifest cache file I/O round-trip");
    }

    // Test 5: Nested array entry round-trip
    {
        auto c = new ManifestCache();
        ManifestCacheEntry e;
        e.name = "NESTED";
        e.typeKind = ManifestTypeKind.nestedArray;
        e.nestedElements = [[1, 2, 3], [4, 5], [6]];
        e.innerElementSize = 1;
        c.entries ~= e;

        auto c2 = ManifestCache.deserialize(c.serialize());
        assert(c2 !is null);
        assert(c2.entries.length == 1);
        assert(c2.entries[0].nestedElements.length == 3);
        assert(c2.entries[0].nestedElements[0] == [1, 2, 3]);
        assert(c2.entries[0].nestedElements[1] == [4, 5]);
        assert(c2.entries[0].nestedElements[2] == [6]);
        assert(c2.entries[0].innerElementSize == 1);

        writefln("  ok: nested array manifest cache round-trip");
    }
}
