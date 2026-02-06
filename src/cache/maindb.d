/**
 * Main Database for Incremental Compilation Cache
 * 
 * Append-only storage with in-memory index. Entries are appended to the end,
 * and the index maps member names to their most recent entry offset.
 * 
 * File format:
 *   [magic: 4 bytes]          - "D2WC" (D2Wasm Cache)
 *   [version: u32]            - Format version (1)
 *   [entries...]              - Serialized CacheEntry records (variable length)
 * 
 * No checksum on the whole file - each CacheEntry has its own checksum.
 * On startup, we scan the file to build the index, validating each entry.
 */
module cache.maindb;

import cache.entry;
import std.file;
import std.path;
import std.array;
import std.algorithm : sort;
import std.stdio : File;
import std.exception;

/// Magic bytes for main database
enum MAINDB_MAGIC = cast(ubyte[4])['D', '2', 'W', 'C'];
enum MAINDB_VERSION = 1;
enum HEADER_SIZE = 8;  // magic(4) + version(4)

/**
 * Main database for cache entries.
 * Append-only with in-memory index for fast lookups.
 */
class MainDatabase {
    private string dbPath;
    private size_t[string] index;  // memberName -> file offset
    private size_t fileSize;
    
    /**
     * Open or create a main database.
     */
    this(string path) {
        this.dbPath = path;
        
        if (exists(path)) {
            loadAndIndex();
        } else {
            createNew();
        }
    }
    
    /**
     * Look up a cache entry by member name.
     * Returns null if not found.
     */
    CacheEntry* lookup(string memberName) {
        auto offsetPtr = memberName in index;
        if (offsetPtr is null) {
            return null;
        }
        
        return readEntryAt(*offsetPtr);
    }
    
    /**
     * Check if a member exists in the cache.
     */
    bool contains(string memberName) {
        return (memberName in index) !is null;
    }
    
    /**
     * Get all cached member names.
     */
    string[] members() {
        return index.keys.sort.array;
    }
    
    /**
     * Number of entries in the cache.
     */
    size_t count() {
        return index.length;
    }
    
    /**
     * Append new entries to the database.
     * Updates the index to point to the new entries.
     */
    bool append(const(CacheEntry)[] entries) {
        if (entries.length == 0) return true;
        
        auto buffer = appender!(ubyte[]);
        foreach (entry; entries) {
            buffer.put(entry.serialize());
        }
        
        try {
            // Append to file
            auto f = File(dbPath, "ab");
            size_t startOffset = fileSize;
            f.rawWrite(buffer.data);
            f.close();
            
            // Update index
            size_t offset = startOffset;
            foreach (entry; entries) {
                index[entry.memberName] = offset;
                auto serialized = entry.serialize();
                offset += serialized.length;
            }
            fileSize = offset;
            
            return true;
        } catch (Exception e) {
            return false;
        }
    }
    
    /**
     * Merge entries from staging files into the database.
     */
    bool mergeFromStaging(string stagingDir) {
        import cache.staging : listStagingFiles, readStagingFile, deleteStagingFile;
        
        auto stagingFiles = listStagingFiles(stagingDir);
        if (stagingFiles.length == 0) return true;
        
        CacheEntry[] allEntries;
        string[] processedFiles;
        
        foreach (stagingPath; stagingFiles) {
            auto result = readStagingFile(stagingPath);
            if (!result.valid) {
                // Invalid staging file - delete it and continue
                deleteStagingFile(stagingPath);
                continue;
            }
            
            allEntries ~= result.entries;
            processedFiles ~= stagingPath;
        }
        
        if (allEntries.length > 0) {
            if (!append(allEntries)) {
                return false;
            }
        }
        
        // Delete processed staging files
        foreach (path; processedFiles) {
            deleteStagingFile(path);
        }
        
        return true;
    }
    
    /**
     * Compact the database by removing old entries.
     * Rewrites the file with only the latest entry for each member.
     */
    bool compact() {
        // Collect current entries
        CacheEntry[] currentEntries;
        foreach (name; index.keys) {
            auto entry = lookup(name);
            if (entry !is null) {
                currentEntries ~= *entry;
            }
        }
        
        // Write to temp file
        string tempPath = dbPath ~ ".compact";
        try {
            auto f = File(tempPath, "wb");
            
            // Write header
            f.rawWrite(MAINDB_MAGIC[]);
            ubyte[4] versionBytes = [
                cast(ubyte)(MAINDB_VERSION & 0xFF),
                cast(ubyte)((MAINDB_VERSION >> 8) & 0xFF),
                cast(ubyte)((MAINDB_VERSION >> 16) & 0xFF),
                cast(ubyte)((MAINDB_VERSION >> 24) & 0xFF)
            ];
            f.rawWrite(versionBytes[]);
            
            // Write entries and rebuild index
            index.clear();
            size_t offset = HEADER_SIZE;
            
            foreach (entry; currentEntries) {
                auto serialized = entry.serialize();
                index[entry.memberName] = offset;
                f.rawWrite(serialized);
                offset += serialized.length;
            }
            
            f.close();
            fileSize = offset;
            
            // Atomic replace
            if (exists(dbPath)) {
                remove(dbPath);
            }
            rename(tempPath, dbPath);
            
            return true;
        } catch (Exception e) {
            if (exists(tempPath)) {
                try { remove(tempPath); } catch (Exception) {}
            }
            return false;
        }
    }
    
    private void createNew() {
        auto f = File(dbPath, "wb");
        f.rawWrite(MAINDB_MAGIC[]);
        ubyte[4] versionBytes = [
            cast(ubyte)(MAINDB_VERSION & 0xFF),
            cast(ubyte)((MAINDB_VERSION >> 8) & 0xFF),
            cast(ubyte)((MAINDB_VERSION >> 16) & 0xFF),
            cast(ubyte)((MAINDB_VERSION >> 24) & 0xFF)
        ];
        f.rawWrite(versionBytes[]);
        f.close();
        
        fileSize = HEADER_SIZE;
        index.clear();
    }
    
    private void loadAndIndex() {
        auto data = cast(ubyte[])std.file.read(dbPath);
        
        if (data.length < HEADER_SIZE) {
            // Invalid file, recreate
            createNew();
            return;
        }
        
        // Check magic
        if (data[0..4] != MAINDB_MAGIC) {
            createNew();
            return;
        }
        
        // Check version
        uint ver = getU32(data, 4);
        if (ver != MAINDB_VERSION) {
            createNew();
            return;
        }
        
        // Scan entries and build index
        index.clear();
        size_t pos = HEADER_SIZE;
        
        while (pos < data.length) {
            // Try to read entry length
            if (pos + 4 > data.length) break;
            
            uint entryLen = getU32(data, pos);
            if (pos + 4 + entryLen > data.length) break;
            
            // Try to deserialize
            auto entry = CacheEntry.deserialize(data[pos .. $]);
            if (entry is null) {
                // Corrupted entry, stop here
                break;
            }
            
            // Update index (last entry for this name wins)
            index[entry.memberName] = pos;
            pos += 4 + entryLen;
        }
        
        fileSize = pos;
    }
    
    private CacheEntry* readEntryAt(size_t offset) {
        auto data = cast(ubyte[])std.file.read(dbPath);
        
        if (offset >= data.length) return null;
        
        return CacheEntry.deserialize(data[offset .. $]);
    }
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
    import cache.staging : writeStagingFile;
    
    string testDir = buildPath(tempDir(), "d2wasm_maindb_test");
    scope(exit) {
        if (exists(testDir)) {
            rmdirRecurse(testDir);
        }
    }
    mkdirRecurse(testDir);
    
    string dbPath = buildPath(testDir, "main.db");
    string stagingDir = buildPath(testDir, "staging");
    
    // Test 1: Create new database
    {
        auto db = new MainDatabase(dbPath);
        assert(db.count == 0, "New db should be empty");
        assert(exists(dbPath), "DB file should exist");
        
        writeln("✓ MainDatabase creation test passed");
    }
    
    // Test 2: Append and lookup
    {
        auto db = new MainDatabase(dbPath);
        
        CacheEntry entry1;
        entry1.memberName = "func1";
        entry1.sourceHash = CacheEntry.computeHash("int func1() {}");
        entry1.dependencies = [];
        entry1.wasmBytes = [0x00, 0x61, 0x73, 0x6D];
        
        bool appended = db.append([entry1]);
        assert(appended, "Append should succeed");
        assert(db.count == 1, "Should have 1 entry");
        assert(db.contains("func1"), "Should contain func1");
        
        auto looked = db.lookup("func1");
        assert(looked !is null, "Lookup should succeed");
        assert(looked.memberName == "func1", "Name mismatch");
        assert(looked.wasmBytes == entry1.wasmBytes, "WASM mismatch");
        
        writeln("✓ MainDatabase append/lookup test passed");
    }
    
    // Test 3: Reopen and persistence
    {
        auto db = new MainDatabase(dbPath);
        assert(db.count == 1, "Should persist entries");
        assert(db.contains("func1"), "Should still contain func1");
        
        writeln("✓ MainDatabase persistence test passed");
    }
    
    // Test 4: Update (append newer version)
    {
        auto db = new MainDatabase(dbPath);
        
        CacheEntry entry1_v2;
        entry1_v2.memberName = "func1";
        entry1_v2.sourceHash = CacheEntry.computeHash("int func1() { return 1; }");
        entry1_v2.dependencies = [];
        entry1_v2.wasmBytes = [0x00, 0x61, 0x73, 0x6D, 0x01];
        
        db.append([entry1_v2]);
        
        auto looked = db.lookup("func1");
        assert(looked.wasmBytes == entry1_v2.wasmBytes, "Should get newer version");
        
        writeln("✓ MainDatabase update test passed");
    }
    
    // Test 5: Merge from staging
    {
        CacheEntry entry2;
        entry2.memberName = "func2";
        entry2.sourceHash = CacheEntry.computeHash("int func2() {}");
        entry2.dependencies = [];
        entry2.wasmBytes = [0x02];
        
        writeStagingFile(stagingDir, "module_a", [entry2]);
        
        auto db = new MainDatabase(dbPath);
        bool merged = db.mergeFromStaging(stagingDir);
        assert(merged, "Merge should succeed");
        assert(db.contains("func2"), "Should contain merged entry");
        
        // Staging file should be deleted
        assert(!exists(buildPath(stagingDir, "module_a.pending")), "Staging should be deleted");
        
        writeln("✓ MainDatabase merge test passed");
    }
    
    // Test 6: Compact
    {
        auto db = new MainDatabase(dbPath);
        auto sizeBefore = getSize(dbPath);
        
        bool compacted = db.compact();
        assert(compacted, "Compact should succeed");
        assert(db.count == 2, "Should still have 2 entries");
        
        auto sizeAfter = getSize(dbPath);
        assert(sizeAfter <= sizeBefore, "Compacted file should not be larger");
        
        // Verify data still valid
        assert(db.contains("func1"), "Should still contain func1");
        assert(db.contains("func2"), "Should still contain func2");
        
        writeln("✓ MainDatabase compact test passed");
    }
    
    writeln("✓ All MainDatabase tests passed");
}
