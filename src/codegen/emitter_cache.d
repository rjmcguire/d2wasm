/**
 * Shared Emitter Cache Interface
 *
 * Defines the cache interface that both WASM and native emitters implement.
 * Allows cache wiring code in main.d to work generically with either emitter.
 */
module codegen.emitter_cache;

import cache.entry : CacheEntry, SourceHash;

/// Cache hit/miss statistics
struct EmitterCacheStats {
    size_t totalFunctions;
    size_t cacheHits;
    size_t cacheMisses;
}

/// Interface for emitters that support per-function code caching
interface EmitterCache {
    /// Set source text for hash computation
    void setSourceText(string source);

    /// Pre-populate the code cache with previously compiled function code
    void setCodeCache(CacheEntry[] entries);

    /// Get all emitted function code as cache entries
    CacheEntry[] getEmittedCode();

    /// Get cache hit/miss statistics
    EmitterCacheStats getCacheStats();

    /// Evict dirty entries from cache by mangled name
    void evictFromCache(const(string[]) dirtyNames);
}
