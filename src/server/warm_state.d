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
import parser.tree_sitter_c : TreeSitterParser, TSInputEdit, TSRange, IncrementalParseResult;
import semantic.module_registry : ModuleRegistry;
import semantic.module_compiler : CompilationController;

class WarmState {
    /// Per-file warm data
    static struct FileState {
        CacheEntry[] cachedEntries;
        DeclDependencyGraph depGraph;
        string sourceText;
        TreeSitterParser parser;  // retained for incremental reparse

        // Pre-computed dirty mangled names from fileChanged (cleared after compile)
        string[] pendingDirtyNames;

        // Stats from last compilation (written by compileFile)
        size_t lastCacheHits;
        size_t lastCacheMisses;
    }

    /// Warm data keyed by absolute input file path
    FileState[string] files;

    /// Project-level warm module registry (shared across all files)
    ModuleRegistry moduleRegistry;

    /// Project-level warm compilation controller (shared across all files)
    CompilationController compilationController;

    /// Source hashes for imported modules (to detect changes)
    size_t[string] importedSourceHashes;  // absPath → hash

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

    /**
     * Incremental file change: reparse with tree-sitter, use dep graph
     * spatial index to identify dirty declarations, compute transitive
     * closure, and store dirty mangled names for the next compile.
     *
     * Returns the number of declarations directly affected by the edit.
     */
    size_t applyFileChange(string absFile, string newText, TSInputEdit* edit) {
        import std.array : appender;

        auto fs = getOrCreate(absFile);
        string oldText = fs.sourceText;
        fs.sourceText = newText;

        // If we have a parser with a retained tree AND an edit descriptor,
        // do incremental reparse to get precise changed byte ranges
        TSRange[] changedRanges;
        if (edit !is null && fs.parser !is null) {
            try {
                auto result = fs.parser.reparseWithChanges(*edit, newText);
                changedRanges = result.changedRanges;
            } catch (Exception) {
                // Fall back to full reparse on error
                fs.parser = null;
            }
        }

        // Ensure parser has the current tree for next time
        if (fs.parser is null) {
            fs.parser = new TreeSitterParser();
            fs.parser.parseString(newText);
            // No retained old tree → can't compute precise ranges
            // The compile step will still do full dep-graph hash comparison
            return 0;
        }

        // If no dep graph yet, can't map ranges to declarations
        if (fs.depGraph is null || changedRanges is null || changedRanges.length == 0)
            return 0;

        // Map changed byte ranges to dep graph nodes via spatial index
        auto directlyChanged = appender!(uint[]);
        foreach (ref r; changedRanges) {
            auto affected = fs.depGraph.findAffectedNodes(absFile, r.start_byte, r.end_byte);
            foreach (nid; affected)
                directlyChanged ~= nid;
        }

        if (directlyChanged[].length == 0)
            return 0;

        // Compute transitive closure
        auto dirtyIds = fs.depGraph.invalidate(directlyChanged[]);

        // Collect mangled names for cache eviction at compile time
        auto dirtyNames = appender!(string[]);
        foreach (did; dirtyIds) {
            auto node = fs.depGraph.getNode(did);
            if (node !is null && node.mangledName.length > 0)
                dirtyNames ~= node.mangledName;
        }

        fs.pendingDirtyNames = dirtyNames[];
        return directlyChanged[].length;
    }
}
