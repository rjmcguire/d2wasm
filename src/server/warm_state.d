/**
 * Warm State — retained across compilations in the compile server.
 *
 * Keeps the code cache and dependency graph in memory, avoiding
 * disk I/O on every compile cycle. The emitter's cache interface
 * (setCodeCache / getEmittedCode) bridges between WarmState and
 * the compilation pipeline.
 */
module server.warm_state;

import cache.entry : CacheEntry, SourceHash;
import incremental.dep_graph : DeclDependencyGraph;

class WarmState {
    /// Per-file warm data
    static struct FileState {
        CacheEntry[] cachedEntries;
        DeclDependencyGraph depGraph;
        string sourceText;

        // Stats from last compilation (written by compileFile)
        size_t lastCacheHits;
        size_t lastCacheMisses;
    }

    /// Warm data keyed by absolute input file path
    FileState[string] files;

    /// Total number of compile requests served
    size_t compilations;

    /// Get or create file state
    FileState* getOrCreate(string filePath) {
        if (filePath !in files)
            files[filePath] = FileState.init;
        return &files[filePath];
    }

    /// Total cached entries across all files
    size_t totalCachedEntries() {
        size_t total;
        foreach (ref fs; files)
            total += fs.cachedEntries.length;
        return total;
    }

    /// Whether any file has a loaded dep graph
    bool hasAnyDepGraph() {
        foreach (ref fs; files)
            if (fs.depGraph !is null)
                return true;
        return false;
    }
}
