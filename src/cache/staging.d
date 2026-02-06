/**
 * Staging File Operations for Incremental Compilation
 * 
 * Staging files are temporary, per-module files written during compilation.
 * After successful compilation, they are merged into main.db.
 * On crash/corruption, they can be safely deleted (no data loss).
 * 
 * File format:
 *   [magic: 4 bytes]          - "STAG" 
 *   [version: u32]            - Format version (1)
 *   [module_name_len: u32]    - Length of module name
 *   [module_name: bytes]      - Module name
 *   [entry_count: u32]        - Number of cache entries
 *   [entries: CacheEntry...]  - Serialized cache entries
 *   [checksum: u32]           - CRC32 of everything above
 */
module cache.staging;

import cache.entry;
import std.file;
import std.path;
import std.digest.crc;
import std.array;
import std.exception;

/// Magic bytes for staging file
enum STAGING_MAGIC = cast(ubyte[4])['S', 'T', 'A', 'G'];
enum STAGING_VERSION = 1;

/**
 * Write a staging file with cache entries for a module.
 * Returns true on success.
 */
bool writeStagingFile(string stagingDir, string moduleName, const(CacheEntry)[] entries) {
    // Ensure staging directory exists
    if (!exists(stagingDir)) {
        mkdirRecurse(stagingDir);
    }
    
    string stagingPath = buildPath(stagingDir, moduleName ~ ".pending");
    
    auto buffer = appender!(ubyte[]);
    
    // Magic
    buffer.put(STAGING_MAGIC[]);
    
    // Version
    putU32(buffer, STAGING_VERSION);
    
    // Module name
    putU32(buffer, cast(uint)moduleName.length);
    buffer.put(cast(const(ubyte)[])moduleName);
    
    // Entry count
    putU32(buffer, cast(uint)entries.length);
    
    // Entries
    foreach (entry; entries) {
        buffer.put(entry.serialize());
    }
    
    // Checksum (of everything so far)
    auto data = buffer.data;
    auto checksum = crc32Of(data);
    buffer.put(checksum[]);
    
    // Write atomically (write to temp, then rename)
    string tempPath = stagingPath ~ ".tmp";
    try {
        std.file.write(tempPath, buffer.data);
        if (exists(stagingPath)) {
            remove(stagingPath);
        }
        rename(tempPath, stagingPath);
        return true;
    } catch (Exception e) {
        // Clean up temp file on failure
        if (exists(tempPath)) {
            try { remove(tempPath); } catch (Exception) {}
        }
        return false;
    }
}

/**
 * Result of reading a staging file
 */
struct StagingFileResult {
    bool valid;
    string moduleName;
    CacheEntry[] entries;
    string error;
}

/**
 * Read and validate a staging file.
 */
StagingFileResult readStagingFile(string stagingPath) {
    StagingFileResult result;
    
    if (!exists(stagingPath)) {
        result.error = "File not found";
        return result;
    }
    
    ubyte[] data;
    try {
        data = cast(ubyte[])std.file.read(stagingPath);
    } catch (Exception e) {
        result.error = "Failed to read file: " ~ e.msg;
        return result;
    }
    
    // Minimum size: magic(4) + version(4) + name_len(4) + entry_count(4) + checksum(4) = 20
    if (data.length < 20) {
        result.error = "File too small";
        return result;
    }
    
    // Verify checksum first
    auto contentData = data[0 .. $ - 4];
    auto storedChecksum = data[$ - 4 .. $];
    auto computedChecksum = crc32Of(contentData);
    
    if (storedChecksum != computedChecksum) {
        result.error = "Checksum mismatch";
        return result;
    }
    
    size_t pos = 0;
    
    // Magic
    if (data[0..4] != STAGING_MAGIC) {
        result.error = "Invalid magic";
        return result;
    }
    pos += 4;
    
    // Version
    uint ver = getU32(data, pos);
    pos += 4;
    if (ver != STAGING_VERSION) {
        result.error = "Unsupported version: " ~ ver.stringof;
        return result;
    }
    
    // Module name
    uint nameLen = getU32(data, pos);
    pos += 4;
    if (pos + nameLen > contentData.length) {
        result.error = "Invalid module name length";
        return result;
    }
    result.moduleName = cast(string)data[pos .. pos + nameLen].dup;
    pos += nameLen;
    
    // Entry count
    uint entryCount = getU32(data, pos);
    pos += 4;
    
    // Entries
    result.entries = new CacheEntry[](entryCount);
    foreach (i; 0 .. entryCount) {
        if (pos >= contentData.length) {
            result.error = "Unexpected end of file reading entry " ~ i.stringof;
            return result;
        }
        
        auto entry = CacheEntry.deserialize(data[pos .. $]);
        if (entry is null) {
            result.error = "Failed to deserialize entry " ~ i.stringof;
            return result;
        }
        result.entries[i] = *entry;
        
        // Move past this entry (need to re-read length)
        uint entryLen = getU32(data, pos);
        pos += 4 + entryLen;
    }
    
    result.valid = true;
    return result;
}

/**
 * List all pending staging files in a directory.
 */
string[] listStagingFiles(string stagingDir) {
    if (!exists(stagingDir)) {
        return [];
    }
    
    string[] files;
    foreach (entry; dirEntries(stagingDir, "*.pending", SpanMode.shallow)) {
        files ~= entry.name;
    }
    return files;
}

/**
 * Delete a staging file (used after successful merge or on corruption).
 */
bool deleteStagingFile(string stagingPath) {
    try {
        if (exists(stagingPath)) {
            remove(stagingPath);
        }
        return true;
    } catch (Exception) {
        return false;
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

// Unit tests
unittest {
    import std.stdio : writeln;
    import std.file : tempDir, rmdirRecurse;
    
    string testDir = buildPath(tempDir(), "d2wasm_staging_test");
    scope(exit) {
        if (exists(testDir)) {
            rmdirRecurse(testDir);
        }
    }
    
    // Test 1: Write and read back staging file
    {
        CacheEntry entry1;
        entry1.memberName = "func1";
        entry1.sourceHash = CacheEntry.computeHash("int func1() { return 1; }");
        entry1.dependencies = [];
        entry1.wasmBytes = [0x00, 0x61, 0x73, 0x6D];
        
        CacheEntry entry2;
        entry2.memberName = "func2";
        entry2.sourceHash = CacheEntry.computeHash("int func2() { return func1(); }");
        entry2.dependencies = [Dependency("func1", entry1.sourceHash)];
        entry2.wasmBytes = [0x00, 0x61, 0x73, 0x6D, 0x01];
        
        bool written = writeStagingFile(testDir, "testmodule", [entry1, entry2]);
        assert(written, "Failed to write staging file");
        
        auto result = readStagingFile(buildPath(testDir, "testmodule.pending"));
        assert(result.valid, "Failed to read staging file: " ~ result.error);
        assert(result.moduleName == "testmodule", "Module name mismatch");
        assert(result.entries.length == 2, "Entry count mismatch");
        assert(result.entries[0].memberName == "func1", "Entry 1 name mismatch");
        assert(result.entries[1].memberName == "func2", "Entry 2 name mismatch");
        assert(result.entries[1].dependencies.length == 1, "Entry 2 deps mismatch");
        
        writeln("✓ Staging file write/read test passed");
    }
    
    // Test 2: Corruption detection
    {
        string path = buildPath(testDir, "testmodule.pending");
        auto data = cast(ubyte[])std.file.read(path);
        
        // Corrupt a byte
        data[20] ^= 0xFF;
        std.file.write(path, data);
        
        auto result = readStagingFile(path);
        assert(!result.valid, "Should detect corruption");
        assert(result.error == "Checksum mismatch", "Wrong error: " ~ result.error);
        
        writeln("✓ Staging file corruption detection test passed");
    }
    
    // Test 3: List staging files
    {
        writeStagingFile(testDir, "module_a", []);
        writeStagingFile(testDir, "module_b", []);
        
        auto files = listStagingFiles(testDir);
        assert(files.length >= 2, "Should list staging files");
        
        writeln("✓ Staging file listing test passed");
    }
    
    // Test 4: Delete staging file
    {
        string path = buildPath(testDir, "module_a.pending");
        assert(exists(path), "File should exist before delete");
        
        bool deleted = deleteStagingFile(path);
        assert(deleted, "Delete should succeed");
        assert(!exists(path), "File should not exist after delete");
        
        writeln("✓ Staging file delete test passed");
    }
    
    writeln("✓ All staging file tests passed");
}
