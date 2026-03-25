/**
 * Cache Entry Format for Incremental Compilation
 * 
 * Binary format:
 *   [entry_length: u32]        - total bytes for this entry (excluding this field)
 *   [member_name_len: u32]     - length of member name
 *   [member_name: bytes]       - member name (e.g., "foo", "Point")
 *   [source_hash: 32 bytes]    - hash of AST S-expression
 *   [dep_count: u32]           - number of dependencies
 *   [deps: array of:]
 *       [name_len: u32]
 *       [name: bytes]
 *       [hash: 32 bytes]
 *   [wasm_length: u32]         - length of compiled WASM
 *   [wasm_bytes: bytes]        - raw WASM bytes
 *   [checksum: u32]            - CRC32 of everything above (after entry_length)
 */
module cache.entry;

import std.digest.crc;
import std.digest.murmurhash;
import std.array;
import std.exception;
import std.algorithm : min;
import std.string : indexOf;

/// 32-byte hash (256 bits) - using MurmurHash3 128-bit, doubled
alias SourceHash = ubyte[32];

/// Dependency with its hash at time of compilation
struct Dependency {
    string name;
    SourceHash hash;
}

/// A cached compilation result for a module member
struct CacheEntry {
    string memberName;
    SourceHash sourceHash;
    Dependency[] dependencies;
    ubyte[] wasmBytes;
    
    /// Compute hash from an S-expression string
    static SourceHash computeHash(const(char)[] sexp) {
        SourceHash result;
        // Use MurmurHash3 128-bit, run twice with different seeds to get 256 bits
        auto hash1 = MurmurHash3!128(0);
        auto hash2 = MurmurHash3!128(0x9E3779B9);  // golden ratio seed
        
        hash1.put(cast(const(ubyte)[])sexp);
        hash2.put(cast(const(ubyte)[])sexp);
        
        result[0..16] = hash1.finish();
        result[16..32] = hash2.finish();
        return result;
    }
    
    /// Serialize to binary format
    ubyte[] serialize() const {
        auto buffer = appender!(ubyte[]);
        
        // We'll write entry_length at the end, reserve space
        size_t startPos = 0;
        buffer.put(cast(ubyte[])([0, 0, 0, 0]));  // placeholder for entry_length
        
        // Member name
        putU32(buffer, cast(uint)memberName.length);
        buffer.put(cast(const(ubyte)[])memberName);
        
        // Source hash
        buffer.put(sourceHash[]);
        
        // Dependencies
        putU32(buffer, cast(uint)dependencies.length);
        foreach (dep; dependencies) {
            putU32(buffer, cast(uint)dep.name.length);
            buffer.put(cast(const(ubyte)[])dep.name);
            buffer.put(dep.hash[]);
        }
        
        // WASM bytes
        putU32(buffer, cast(uint)wasmBytes.length);
        buffer.put(wasmBytes);
        
        // Calculate checksum (of everything after entry_length)
        auto data = buffer.data;
        auto checksumData = data[4..$];  // skip entry_length placeholder
        auto crc = crc32Of(checksumData);
        buffer.put(crc[]);
        
        // Now write entry_length at the start
        data = buffer.data;
        uint entryLength = cast(uint)(data.length - 4);  // exclude entry_length itself
        data[0] = cast(ubyte)(entryLength & 0xFF);
        data[1] = cast(ubyte)((entryLength >> 8) & 0xFF);
        data[2] = cast(ubyte)((entryLength >> 16) & 0xFF);
        data[3] = cast(ubyte)((entryLength >> 24) & 0xFF);
        
        return data;
    }
    
    /// Deserialize from binary format. Returns null on error.
    static CacheEntry* deserialize(const(ubyte)[] data) {
        if (data.length < 4) return null;
        
        size_t pos = 0;
        
        // Entry length
        uint entryLength = getU32(data, pos);
        pos += 4;
        
        if (data.length < 4 + entryLength) return null;
        
        // Verify checksum first
        auto entryData = data[4 .. 4 + entryLength];
        if (entryLength < 4) return null;
        
        auto contentData = entryData[0 .. $ - 4];
        auto storedChecksum = entryData[$ - 4 .. $];
        auto computedChecksum = crc32Of(contentData);
        
        if (storedChecksum != computedChecksum) return null;
        
        // Now parse the content
        auto entry = new CacheEntry();
        pos = 0;
        
        // Member name
        if (contentData.length < pos + 4) return null;
        uint nameLen = getU32(contentData, pos);
        pos += 4;
        if (contentData.length < pos + nameLen) return null;
        entry.memberName = cast(string)contentData[pos .. pos + nameLen].dup;
        pos += nameLen;
        
        // Source hash
        if (contentData.length < pos + 32) return null;
        entry.sourceHash = contentData[pos .. pos + 32][0..32];
        pos += 32;
        
        // Dependencies
        if (contentData.length < pos + 4) return null;
        uint depCount = getU32(contentData, pos);
        pos += 4;
        
        entry.dependencies = new Dependency[depCount];
        foreach (i; 0 .. depCount) {
            if (contentData.length < pos + 4) return null;
            uint depNameLen = getU32(contentData, pos);
            pos += 4;
            if (contentData.length < pos + depNameLen) return null;
            entry.dependencies[i].name = cast(string)contentData[pos .. pos + depNameLen].dup;
            pos += depNameLen;
            if (contentData.length < pos + 32) return null;
            entry.dependencies[i].hash = contentData[pos .. pos + 32][0..32];
            pos += 32;
        }
        
        // WASM bytes
        if (contentData.length < pos + 4) return null;
        uint wasmLen = getU32(contentData, pos);
        pos += 4;
        if (contentData.length < pos + wasmLen) return null;
        entry.wasmBytes = contentData[pos .. pos + wasmLen].dup;
        
        return entry;
    }
}

/// Write a u32 in little-endian
private void putU32(ref Appender!(ubyte[]) buffer, uint value) {
    buffer.put(cast(ubyte)(value & 0xFF));
    buffer.put(cast(ubyte)((value >> 8) & 0xFF));
    buffer.put(cast(ubyte)((value >> 16) & 0xFF));
    buffer.put(cast(ubyte)((value >> 24) & 0xFF));
}

/// Read a u32 in little-endian
private uint getU32(const(ubyte)[] data, size_t pos) {
    return cast(uint)data[pos] |
           (cast(uint)data[pos + 1] << 8) |
           (cast(uint)data[pos + 2] << 16) |
           (cast(uint)data[pos + 3] << 24);
}

// Unittests
unittest {
    import std.stdio : writeln;
    
    // Test 1: Basic round-trip
    {
        CacheEntry original;
        original.memberName = "testFunc";
        original.sourceHash = CacheEntry.computeHash("(function_declaration (identifier) (parameters))");
        original.dependencies = [
            Dependency("helper", CacheEntry.computeHash("(function_declaration helper)")),
            Dependency("Point", CacheEntry.computeHash("(struct_declaration Point)"))
        ];
        original.wasmBytes = cast(ubyte[])[0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00];  // WASM magic
        
        auto serialized = original.serialize();
        auto deserialized = CacheEntry.deserialize(serialized);
        
        assert(deserialized !is null, "Deserialization failed");
        assert(deserialized.memberName == original.memberName, "Member name mismatch");
        assert(deserialized.sourceHash == original.sourceHash, "Source hash mismatch");
        assert(deserialized.dependencies.length == original.dependencies.length, "Dep count mismatch");
        assert(deserialized.dependencies[0].name == "helper", "Dep name mismatch");
        assert(deserialized.dependencies[0].hash == original.dependencies[0].hash, "Dep hash mismatch");
        assert(deserialized.wasmBytes == original.wasmBytes, "WASM bytes mismatch");
        
        writeln("✓ Cache entry round-trip test passed");
    }
    
    // Test 2: Empty dependencies
    {
        CacheEntry original;
        original.memberName = "standalone";
        original.sourceHash = CacheEntry.computeHash("(function_declaration standalone)");
        original.dependencies = [];
        original.wasmBytes = [0x00, 0x61, 0x73, 0x6D];
        
        auto serialized = original.serialize();
        auto deserialized = CacheEntry.deserialize(serialized);
        
        assert(deserialized !is null, "Deserialization failed for empty deps");
        assert(deserialized.dependencies.length == 0, "Should have no deps");
        
        writeln("✓ Empty dependencies test passed");
    }
    
    // Test 3: Corrupted data detected
    {
        CacheEntry original;
        original.memberName = "test";
        original.sourceHash = CacheEntry.computeHash("test");
        original.dependencies = [];
        original.wasmBytes = [0x00];
        
        auto serialized = original.serialize();
        
        // Corrupt a byte
        serialized[10] ^= 0xFF;
        
        auto deserialized = CacheEntry.deserialize(serialized);
        assert(deserialized is null, "Should detect corruption");
        
        writeln("✓ Corruption detection test passed");
    }
    
    // Test 4: Hash consistency
    {
        auto hash1 = CacheEntry.computeHash("(function_declaration foo)");
        auto hash2 = CacheEntry.computeHash("(function_declaration foo)");
        auto hash3 = CacheEntry.computeHash("(function_declaration bar)");
        
        assert(hash1 == hash2, "Same input should produce same hash");
        assert(hash1 != hash3, "Different input should produce different hash");
        
        writeln("✓ Hash consistency test passed");
    }
    
    // Test 5: Source-based hashing (semantic changes detected)
    {
        // Different code should have different hash
        string code1 = "int add(int a, int b) { return a + b; }";
        string code2 = "int sub(int a, int b) { return a - b; }";
        
        auto hash1 = CacheEntry.computeHash(code1);
        auto hash2 = CacheEntry.computeHash(code2);
        
        assert(hash1 != hash2, "Different functions should have different hashes");
        
        // Same code should have same hash
        auto hash3 = CacheEntry.computeHash(code1);
        assert(hash1 == hash3, "Same code should have same hash");
        
        writeln("✓ Source-based hashing test passed");
    }
    
    // Test 6: Tree-sitter S-expression available (for future optimization)
    {
        import parser.tree_sitter_c : TreeSitterParser;
        
        auto parser = new TreeSitterParser();
        string code = "int add(int a, int b) { return a + b; }";
        auto node = parser.parseString(code);
        auto sexp = TreeSitterParser.getNodeSexp(node);
        
        // S-expression should exist and contain structure
        assert(sexp.length > 0, "S-expression should not be empty");
        assert(sexp.indexOf("function_declaration") >= 0, "Should contain function_declaration");
        
        writeln("✓ Tree-sitter S-expression available");
    }

    // Test 7: Cache handles non-WASM binary data (native ARM64 bytes)
    {
        // Simulate ARM64 machine code (arbitrary bytes, not valid WASM)
        ubyte[] nativeBytes = [
            0xFD, 0x7B, 0xBF, 0xA9,  // stp x29, x30, [sp, #-16]!  (prologue)
            0xFD, 0x03, 0x00, 0x91,  // mov x29, sp
            0x00, 0x00, 0x80, 0xD2,  // mov x0, #0
            0xFD, 0x7B, 0xC1, 0xA8,  // ldp x29, x30, [sp], #16     (epilogue)
            0xC0, 0x03, 0x5F, 0xD6,  // ret
        ];

        CacheEntry entry;
        entry.memberName = "_D4test4mainFZi";
        entry.sourceHash = CacheEntry.computeHash("int main() { return 0; }");
        entry.wasmBytes = nativeBytes;  // field name is "wasmBytes" but it's just ubyte[]

        // Serialize and deserialize
        auto serialized = entry.serialize();
        assert(serialized.length > 0, "Serialized native cache entry should not be empty");

        auto deserialized = CacheEntry.deserialize(serialized);
        assert(deserialized.memberName == "_D4test4mainFZi");
        assert(deserialized.wasmBytes == nativeBytes, "Native bytes should survive round-trip");
        assert(deserialized.sourceHash == entry.sourceHash);

        writeln("✓ Cache handles native ARM64 binary data");
    }
}
