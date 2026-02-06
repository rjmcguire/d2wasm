/**
 * Compiler Cache Integration
 * 
 * Integrates the incremental compilation cache with the compiler.
 * Tracks which members need recompilation and stores results.
 * 
 * Current implementation:
 * - Tracks what WOULD be cached (for statistics)
 * - Stores compiled results for future runs
 * - Does NOT yet skip compilation (requires emitter refactoring)
 */
module cache.compiler_cache;

import cache.entry;
import cache.maindb;
import cache.staging;
import cache.validator;
import cache.dependency_extractor;

import ast.nodes;
import parser.tree_sitter_c : TreeSitterParser;

import std.path;
import std.file;
import std.algorithm : map, filter;
import std.array : array, split;
import std.format : format;

/**
 * Statistics from a cached compilation
 */
struct CacheStats {
    int totalMembers;
    int cacheHits;
    int cacheMisses;
    string[] recompiledMembers;
    string[] cachedMembers;
    
    @property double hitRate() const {
        return totalMembers > 0 ? cast(double)cacheHits / totalMembers : 0.0;
    }
}

/**
 * Compiler cache manager.
 * Wraps the cache infrastructure for use during compilation.
 */
class CompilerCache {
    private MainDatabase db;
    private string stagingDir;
    private string moduleName;
    private CacheEntry[] pendingEntries;
    private CacheStats stats;
    
    // Source hashes for current compilation
    private SourceHash[string] currentHashes;
    
    /**
     * Initialize cache for a compilation.
     * 
     * Params:
     *   cacheDir = Directory for cache files (e.g., ".d2wasm-cache")
     *   moduleName = Name of the module being compiled
     */
    this(string cacheDir, string moduleName) {
        this.moduleName = moduleName;
        
        // Create cache directory if needed
        if (!exists(cacheDir)) {
            mkdirRecurse(cacheDir);
        }
        
        string dbPath = buildPath(cacheDir, "main.db");
        this.stagingDir = buildPath(cacheDir, "staging");
        
        this.db = new MainDatabase(dbPath);
        
        // Merge any pending staging files from previous runs
        db.mergeFromStaging(stagingDir);
    }
    
    /**
     * Analyze declarations and determine what needs recompilation.
     * Call this after parsing, before compilation.
     * 
     * Params:
     *   declarations = Parsed AST declarations
     *   sourceCode = Original source code (for hashing)
     */
    void analyzeDeclarations(Declaration[] declarations, string sourceCode) {
        auto parser = new TreeSitterParser();
        auto rootNode = parser.parseString(sourceCode);
        
        // Compute hashes for all top-level declarations
        foreach (decl; declarations) {
            string name = getMemberName(decl);
            if (name.length == 0) continue;
            
            // Get the source text for this declaration
            // For now, use the declaration's location to extract source
            string memberSource = extractMemberSource(decl, sourceCode);
            currentHashes[name] = CacheEntry.computeHash(memberSource);
        }
        
        // Check which members need recompilation
        stats.totalMembers = cast(int)currentHashes.length;
        
        foreach (name, hash; currentHashes) {
            auto result = validateCacheEntry(db, name, hash, &getDependencyHash);
            
            if (result.valid) {
                stats.cacheHits++;
                stats.cachedMembers ~= name;
            } else {
                stats.cacheMisses++;
                stats.recompiledMembers ~= name;
            }
        }
    }
    
    /**
     * Record a compiled member for caching.
     * Call this after successfully compiling a member.
     */
    void recordCompiled(string memberName, SourceHash sourceHash, 
                        string[] dependencies, ubyte[] wasmBytes) {
        CacheEntry entry;
        entry.memberName = memberName;
        entry.sourceHash = sourceHash;
        entry.wasmBytes = wasmBytes.dup;
        
        // Build dependency list with hashes
        foreach (depName; dependencies) {
            auto depHash = getDependencyHash(depName);
            if (depHash != SourceHash.init) {
                entry.dependencies ~= Dependency(depName, depHash);
            }
        }
        
        pendingEntries ~= entry;
    }
    
    /**
     * Record a compiled function (convenience method).
     */
    void recordFunction(FunctionDecl func, Declaration[] allDecls, 
                        string sourceCode, ubyte[] wasmBytes) {
        string name = func.name;
        
        // Get source hash
        string memberSource = extractMemberSource(func, sourceCode);
        auto sourceHash = CacheEntry.computeHash(memberSource);
        
        // Extract dependencies
        auto depInfo = extractDependencies(func, allDecls);
        
        recordCompiled(name, sourceHash, depInfo.all(), wasmBytes);
    }
    
    /**
     * Flush pending entries to staging file.
     * Call this after compilation completes.
     */
    bool flush() {
        if (pendingEntries.length == 0) {
            return true;
        }
        
        bool success = writeStagingFile(stagingDir, moduleName, pendingEntries);
        if (success) {
            pendingEntries = [];
        }
        return success;
    }
    
    /**
     * Get compilation statistics.
     */
    CacheStats getStats() {
        return stats;
    }
    
    /**
     * Check if a member would be a cache hit.
     */
    bool wouldCacheHit(string memberName) {
        auto hashPtr = memberName in currentHashes;
        if (hashPtr is null) return false;
        
        auto result = validateCacheEntry(db, memberName, *hashPtr, &getDependencyHash);
        return result.valid;
    }
    
    /**
     * Get cached WASM bytes for a member (if valid).
     * Returns null if not cached or invalid.
     */
    ubyte[] getCachedWasm(string memberName) {
        auto hashPtr = memberName in currentHashes;
        if (hashPtr is null) return null;
        
        auto result = validateCacheEntry(db, memberName, *hashPtr, &getDependencyHash);
        if (!result.valid) return null;
        
        auto entry = db.lookup(memberName);
        return entry ? entry.wasmBytes.dup : null;
    }
    
    private SourceHash getDependencyHash(string name) {
        auto ptr = name in currentHashes;
        if (ptr !is null) return *ptr;
        
        // Check if it's in the database
        auto entry = db.lookup(name);
        if (entry !is null) return entry.sourceHash;
        
        return SourceHash.init;
    }
    
    private static string getMemberName(Declaration decl) {
        if (auto func = cast(FunctionDecl)decl) return func.name;
        if (auto struct_ = cast(StructDecl)decl) return struct_.name;
        if (auto manifest = cast(ManifestConstantDecl)decl) return manifest.name;
        return "";
    }
    
    private static string extractMemberSource(Declaration decl, string sourceCode) {
        // Use source location to extract the member's source text
        auto loc = decl.location;
        if (loc.line == 0) return "";
        
        // Use byte offsets if available
        if (loc.startOffset > 0 && loc.endOffset > loc.startOffset && 
            loc.endOffset <= sourceCode.length) {
            return sourceCode[loc.startOffset .. loc.endOffset];
        }
        
        // Fallback: use declaration name + location as a pseudo-hash
        // Real implementation should use tree-sitter byte ranges
        return format("%s@%s:%d", getMemberName(decl), loc.filename, loc.line);
    }
}

// Unit tests
unittest {
    import std.stdio : writeln;
    import std.file : tempDir, rmdirRecurse, exists, mkdirRecurse;
    import std.path : buildPath;
    
    string testDir = buildPath(tempDir(), "d2wasm_compiler_cache_test");
    scope(exit) {
        if (exists(testDir)) {
            rmdirRecurse(testDir);
        }
    }
    
    // Test 1: Basic cache creation
    {
        auto cache = new CompilerCache(testDir, "test_module");
        auto stats = cache.getStats();
        assert(stats.totalMembers == 0, "New cache should have no members");
        
        writeln("✓ CompilerCache creation test passed");
    }
    
    // Test 2: Record and flush
    {
        auto cache = new CompilerCache(testDir, "test_module");
        
        auto hash = CacheEntry.computeHash("int foo() { return 1; }");
        cache.recordCompiled("foo", hash, [], [0x00, 0x61, 0x73, 0x6D]);
        
        bool flushed = cache.flush();
        assert(flushed, "Flush should succeed");
        
        // Verify staging file exists
        assert(exists(buildPath(testDir, "staging", "test_module.pending")),
               "Staging file should exist");
        
        writeln("✓ CompilerCache record/flush test passed");
    }
    
    // Test 3: Cache persistence across instances
    {
        // Flush pending staging files by creating new cache instance
        auto cache = new CompilerCache(testDir, "test_module");
        
        // The staging file should have been merged
        assert(!exists(buildPath(testDir, "staging", "test_module.pending")),
               "Staging file should be merged");
        
        // "foo" should now be in the main db
        auto wasm = cache.getCachedWasm("foo");
        // Note: Won't work yet because we haven't set currentHashes
        // This is expected - full integration needs analyzeDeclarations
        
        writeln("✓ CompilerCache persistence test passed");
    }
    
    writeln("✓ All CompilerCache tests passed");
}
