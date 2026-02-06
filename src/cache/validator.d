/**
 * Cache Validator for Incremental Compilation
 * 
 * Determines if a cached entry is still valid by checking:
 * 1. Source hash matches current source
 * 2. All dependency hashes match current dependency sources
 * 
 * If valid, the cached WASM can be reused without recompilation.
 */
module cache.validator;

import cache.entry;
import cache.maindb;
import std.algorithm : map, all;
import std.array : array;

/**
 * Result of cache validation
 */
struct ValidationResult {
    bool valid;
    string reason;  // Why invalid (for debugging)
    
    static ValidationResult hit() {
        return ValidationResult(true, "cache hit");
    }
    
    static ValidationResult miss(string reason) {
        return ValidationResult(false, reason);
    }
}

/**
 * Validate if a cache entry is still current.
 * 
 * Params:
 *   db = Main database to look up dependency entries
 *   memberName = Name of the member to validate
 *   currentSourceHash = Hash of the current source for this member
 *   getCurrentDepHash = Function to get current hash for a dependency name
 *                       Returns null if dependency doesn't exist
 */
ValidationResult validateCacheEntry(
    MainDatabase db,
    string memberName,
    SourceHash currentSourceHash,
    SourceHash delegate(string) getCurrentDepHash
) {
    // Look up cached entry
    auto cached = db.lookup(memberName);
    if (cached is null) {
        return ValidationResult.miss("not in cache");
    }
    
    // Check source hash
    if (cached.sourceHash != currentSourceHash) {
        return ValidationResult.miss("source changed");
    }
    
    // Check all dependency hashes
    foreach (dep; cached.dependencies) {
        auto currentHash = getCurrentDepHash(dep.name);
        if (currentHash == SourceHash.init) {
            return ValidationResult.miss("dependency '" ~ dep.name ~ "' not found");
        }
        if (currentHash != dep.hash) {
            return ValidationResult.miss("dependency '" ~ dep.name ~ "' changed");
        }
    }
    
    return ValidationResult.hit();
}

/**
 * Batch validate multiple members.
 * Returns array of member names that need recompilation.
 */
string[] findMembersToRecompile(
    MainDatabase db,
    string[] memberNames,
    SourceHash delegate(string) getCurrentHash
) {
    string[] needsRecompile;
    
    foreach (name; memberNames) {
        auto currentHash = getCurrentHash(name);
        if (currentHash == SourceHash.init) {
            // New member, not in source
            continue;
        }
        
        auto result = validateCacheEntry(db, name, currentHash, getCurrentHash);
        if (!result.valid) {
            needsRecompile ~= name;
        }
    }
    
    return needsRecompile;
}

// Unit tests
unittest {
    import std.stdio : writeln;
    import std.file : tempDir, rmdirRecurse, exists, mkdirRecurse;
    import std.path : buildPath;
    
    string testDir = buildPath(tempDir(), "d2wasm_validator_test");
    scope(exit) {
        if (exists(testDir)) {
            rmdirRecurse(testDir);
        }
    }
    mkdirRecurse(testDir);
    
    string dbPath = buildPath(testDir, "main.db");
    
    // Setup: create database with some entries
    {
        auto db = new MainDatabase(dbPath);
        
        auto hashA = CacheEntry.computeHash("int funcA() { return 1; }");
        auto hashB = CacheEntry.computeHash("int funcB() { return funcA(); }");
        auto hashPoint = CacheEntry.computeHash("struct Point { int x; int y; }");
        
        CacheEntry entryA;
        entryA.memberName = "funcA";
        entryA.sourceHash = hashA;
        entryA.dependencies = [];
        entryA.wasmBytes = [0x01];
        
        CacheEntry entryB;
        entryB.memberName = "funcB";
        entryB.sourceHash = hashB;
        entryB.dependencies = [Dependency("funcA", hashA)];
        entryB.wasmBytes = [0x02];
        
        CacheEntry entryPoint;
        entryPoint.memberName = "Point";
        entryPoint.sourceHash = hashPoint;
        entryPoint.dependencies = [];
        entryPoint.wasmBytes = [0x03];
        
        db.append([entryA, entryB, entryPoint]);
    }
    
    // Test 1: Cache hit (nothing changed)
    {
        auto db = new MainDatabase(dbPath);
        
        auto hashA = CacheEntry.computeHash("int funcA() { return 1; }");
        
        SourceHash getHash(string name) {
            if (name == "funcA") return hashA;
            return SourceHash.init;
        }
        
        auto result = validateCacheEntry(db, "funcA", hashA, &getHash);
        assert(result.valid, "Should be cache hit: " ~ result.reason);
        
        writeln("✓ Cache hit test passed");
    }
    
    // Test 2: Cache miss (source changed)
    {
        auto db = new MainDatabase(dbPath);
        
        auto newHashA = CacheEntry.computeHash("int funcA() { return 2; }");  // Changed!
        
        SourceHash getHash(string name) {
            if (name == "funcA") return newHashA;
            return SourceHash.init;
        }
        
        auto result = validateCacheEntry(db, "funcA", newHashA, &getHash);
        assert(!result.valid, "Should be cache miss");
        assert(result.reason == "source changed", "Wrong reason: " ~ result.reason);
        
        writeln("✓ Cache miss (source changed) test passed");
    }
    
    // Test 3: Cache miss (dependency changed)
    {
        auto db = new MainDatabase(dbPath);
        
        auto hashB = CacheEntry.computeHash("int funcB() { return funcA(); }");
        auto newHashA = CacheEntry.computeHash("int funcA() { return 99; }");  // funcA changed!
        
        SourceHash getHash(string name) {
            if (name == "funcA") return newHashA;
            if (name == "funcB") return hashB;
            return SourceHash.init;
        }
        
        auto result = validateCacheEntry(db, "funcB", hashB, &getHash);
        assert(!result.valid, "Should be cache miss");
        assert(result.reason == "dependency 'funcA' changed", "Wrong reason: " ~ result.reason);
        
        writeln("✓ Cache miss (dependency changed) test passed");
    }
    
    // Test 4: Cache miss (not in cache)
    {
        auto db = new MainDatabase(dbPath);
        
        auto hashNew = CacheEntry.computeHash("int newFunc() {}");
        
        SourceHash getHash(string name) {
            return SourceHash.init;
        }
        
        auto result = validateCacheEntry(db, "newFunc", hashNew, &getHash);
        assert(!result.valid, "Should be cache miss");
        assert(result.reason == "not in cache", "Wrong reason: " ~ result.reason);
        
        writeln("✓ Cache miss (not in cache) test passed");
    }
    
    // Test 5: Batch validation
    {
        auto db = new MainDatabase(dbPath);
        
        auto hashA = CacheEntry.computeHash("int funcA() { return 1; }");
        auto newHashB = CacheEntry.computeHash("int funcB() { return funcA() + 1; }");  // Changed!
        auto hashPoint = CacheEntry.computeHash("struct Point { int x; int y; }");
        
        SourceHash getHash(string name) {
            if (name == "funcA") return hashA;
            if (name == "funcB") return newHashB;
            if (name == "Point") return hashPoint;
            return SourceHash.init;
        }
        
        auto needsRecompile = findMembersToRecompile(db, ["funcA", "funcB", "Point"], &getHash);
        
        assert(needsRecompile.length == 1, "Should have 1 member to recompile");
        assert(needsRecompile[0] == "funcB", "funcB should need recompile");
        
        writeln("✓ Batch validation test passed");
    }
    
    writeln("✓ All validator tests passed");
}
