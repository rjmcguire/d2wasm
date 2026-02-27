/**
 * Declaration dependency graph for incremental compilation.
 *
 * Each declaration in the AST gets a node. Edges record dependencies:
 * function calls, type references, manifest constant reads, method-of
 * relationships. Given a set of changed byte ranges (from tree-sitter
 * incremental parsing), the graph can compute the transitive set of
 * affected declarations that need re-processing.
 *
 * Node identity: uint IDs assigned during graph building.
 * Spatial index: byte ranges map tree-sitter changes to node IDs.
 */
module incremental.dep_graph;

import std.algorithm : sort, uniq, filter, map, canFind;
import std.array : array, appender;
import std.format : format;

/// Kind of dependency edge between declarations.
enum EdgeKind : ubyte {
    calls,          /// function A calls function B
    usesType,       /// declaration A references struct/class/enum S
    readsManifest,  /// declaration A reads manifest constant M
    methodOf,       /// method M belongs to struct/class S
}

/// A node in the dependency graph, representing one declaration.
struct DeclNode {
    uint id;
    string filename;
    uint startByte;       /// from SourceLocation.startOffset
    uint endByte;         /// from SourceLocation.endOffset
    string name;          /// human-readable label
    string kind;          /// "function", "struct", "class", "manifest", "template", "global"
    ulong signatureHash;  /// hash of signature (params+return for func, fields for struct)
    ulong sourceHash;     /// hash of full source text
}

/// A directed edge: `from` depends on `to`.
struct DeclEdge {
    uint from;      /// depends on...
    uint to;        /// ...this
    EdgeKind kind;
}

/**
 * Dependency graph over declarations.
 *
 * Supports:
 *   - Registration of declaration nodes with byte ranges
 *   - Recording typed dependency edges
 *   - Spatial lookup: byte range -> overlapping nodes
 *   - Transitive invalidation via reverse edges
 */
class DeclDependencyGraph {

    // --- Node storage ---
    DeclNode[] nodes;
    private uint nextId;

    // --- Edge storage ---
    DeclEdge[] edges;

    // --- Adjacency (forward + reverse) ---
    uint[][uint] dependsOn;      /// node -> nodes it depends on
    uint[][uint] dependedOnBy;   /// node -> nodes that depend on it

    // --- Spatial index: file -> node IDs sorted by startByte ---
    uint[][string] nodesByFile;

    // ------------------------------------------------------------------
    //  Node registration
    // ------------------------------------------------------------------

    /**
     * Register a declaration node. Returns its unique ID.
     */
    uint addNode(string filename, uint startByte, uint endByte,
                 string name, string kind, ulong sigHash, ulong srcHash) {
        uint id = nextId++;
        nodes ~= DeclNode(id, filename, startByte, endByte, name, kind, sigHash, srcHash);

        // Spatial index
        if (filename !in nodesByFile)
            nodesByFile[filename] = [];
        nodesByFile[filename] ~= id;

        return id;
    }

    // ------------------------------------------------------------------
    //  Edge recording
    // ------------------------------------------------------------------

    /**
     * Record a dependency edge: `from` depends on `to` with the given kind.
     * Duplicate edges are allowed (they don't affect correctness).
     */
    void addEdge(uint from, uint to, EdgeKind kind) {
        edges ~= DeclEdge(from, to, kind);

        if (from !in dependsOn)
            dependsOn[from] = [];
        dependsOn[from] ~= to;

        if (to !in dependedOnBy)
            dependedOnBy[to] = [];
        dependedOnBy[to] ~= from;
    }

    // ------------------------------------------------------------------
    //  Spatial queries
    // ------------------------------------------------------------------

    /**
     * Find node IDs whose byte range overlaps [startByte, endByte) in the given file.
     */
    uint[] findAffectedNodes(string filename, uint startByte, uint endByte) {
        auto fileNodes = filename in nodesByFile;
        if (fileNodes is null)
            return [];

        auto result = appender!(uint[]);
        foreach (nid; *fileNodes) {
            auto node = &nodes[nid];
            // Overlap test: NOT (node.end <= start OR node.start >= end)
            if (!(node.endByte <= startByte || node.startByte >= endByte))
                result ~= nid;
        }
        return result[];
    }

    // ------------------------------------------------------------------
    //  Transitive invalidation
    // ------------------------------------------------------------------

    /**
     * Compute the transitive closure of affected nodes by walking reverse
     * edges from the initial changed set.  Returns a deduplicated, sorted
     * array of all affected node IDs (including the input set).
     */
    uint[] invalidate(uint[] changedNodeIds) {
        bool[uint] visited;
        auto queue = appender!(uint[]);

        // Seed
        foreach (nid; changedNodeIds) {
            if (nid !in visited) {
                visited[nid] = true;
                queue ~= nid;
            }
        }

        // BFS over reverse edges
        size_t head = 0;
        while (head < queue[].length) {
            uint current = queue[][head++];
            if (auto rev = current in dependedOnBy) {
                foreach (dep; *rev) {
                    if (dep !in visited) {
                        visited[dep] = true;
                        queue ~= dep;
                    }
                }
            }
        }

        auto result = visited.keys;
        result.sort();
        return result;
    }

    // ------------------------------------------------------------------
    //  Diagnostics
    // ------------------------------------------------------------------

    /**
     * Print summary statistics.
     */
    void printStats() {
        import std.stdio : writefln;

        writefln("Dependency graph: %d nodes, %d edges", nodes.length, edges.length);

        // Per-kind counts
        uint[string] kindCounts;
        foreach (ref n; nodes)
            kindCounts[n.kind]++;
        foreach (k; kindCounts.byKeyValue())
            writefln("  %s: %d", k.key, k.value);

        // Per-edge-kind counts
        uint[4] edgeKindCounts;
        foreach (ref e; edges)
            edgeKindCounts[e.kind]++;
        static immutable string[] edgeNames = ["calls", "usesType", "readsManifest", "methodOf"];
        foreach (i; 0 .. 4) {
            if (edgeKindCounts[i] > 0)
                writefln("  edges.%s: %d", edgeNames[i], edgeKindCounts[i]);
        }

        // Per-file breakdown
        writefln("  files: %d", nodesByFile.length);
        foreach (fname; nodesByFile.byKey()) {
            writefln("    %s: %d nodes", fname, nodesByFile[fname].length);
        }
    }

    /**
     * Look up a node by its ID. Returns null if out of range.
     */
    const(DeclNode)* getNode(uint id) {
        if (id < nodes.length)
            return &nodes[id];
        return null;
    }
}
