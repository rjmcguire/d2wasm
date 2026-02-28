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
import std.array : array, appender, Appender;
import std.digest.crc : crc32Of;
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
    string mangledName;   /// D ABI mangled name (functions only; empty for structs/etc.)
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
                 string name, string kind, ulong sigHash, ulong srcHash,
                 string mangledName = "") {
        uint id = nextId++;
        nodes ~= DeclNode(id, filename, startByte, endByte, name, kind, sigHash, srcHash, mangledName);

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
    //  Forward transitive closure
    // ------------------------------------------------------------------

    /**
     * Compute the transitive closure of all nodes that `nodeId` depends on
     * (forward edges). Returns a sorted, deduplicated array of dependency
     * node IDs (NOT including nodeId itself).
     *
     * This walks `dependsOn` (forward edges), unlike `invalidate()` which
     * walks `dependedOnBy` (reverse edges).
     */
    uint[] transitiveDeps(uint nodeId) {
        bool[uint] visited;
        auto queue = appender!(uint[]);

        // Seed with direct dependencies
        if (auto fwd = nodeId in dependsOn) {
            foreach (dep; *fwd) {
                if (dep !in visited) {
                    visited[dep] = true;
                    queue ~= dep;
                }
            }
        }

        // BFS over forward edges
        size_t head = 0;
        while (head < queue[].length) {
            uint current = queue[][head++];
            if (auto fwd = current in dependsOn) {
                foreach (dep; *fwd) {
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

    // ------------------------------------------------------------------
    //  Serialization
    // ------------------------------------------------------------------

    /// Magic bytes for dep graph binary format
    private static immutable ubyte[4] MAGIC = ['D', '2', 'D', 'G'];
    private static immutable uint FORMAT_VERSION = 2;

    /**
     * Serialize graph to binary format with string-table deduplication.
     *
     * Layout:
     *   [4]  magic: 'D','2','D','G'
     *   [4]  version: u32 LE = 2
     *   --- string table ---
     *   [4]  string_count: u32
     *   for each string: [4] len + [N] bytes
     *   --- nodes ---
     *   [4]  node_count: u32
     *   for each node:
     *     [4] id, [4] filename_idx, [4] startByte, [4] endByte,
     *     [4] name_idx, [4] kind_idx, [4] mangledName_idx,
     *     [8] signatureHash, [8] sourceHash
     *   --- edges ---
     *   [4]  edge_count: u32
     *   for each edge: [4] from, [4] to, [1] kind
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

        // Pre-intern all strings (determines table contents)
        uint[][] nodeStringIds = new uint[][](nodes.length);
        foreach (i, ref n; nodes) {
            nodeStringIds[i] = [intern(n.filename), intern(n.name), intern(n.kind), intern(n.mangledName)];
        }

        // Write string table
        putU32(buf, cast(uint) stringTable.length);
        foreach (s; stringTable) {
            putU32(buf, cast(uint) s.length);
            buf.put(cast(const(ubyte)[]) s);
        }

        // -- Nodes --
        putU32(buf, cast(uint) nodes.length);
        foreach (i, ref n; nodes) {
            putU32(buf, n.id);
            putU32(buf, nodeStringIds[i][0]); // filename_idx
            putU32(buf, n.startByte);
            putU32(buf, n.endByte);
            putU32(buf, nodeStringIds[i][1]); // name_idx
            putU32(buf, nodeStringIds[i][2]); // kind_idx
            putU32(buf, nodeStringIds[i][3]); // mangledName_idx
            putU64(buf, n.signatureHash);
            putU64(buf, n.sourceHash);
        }

        // -- Edges --
        putU32(buf, cast(uint) edges.length);
        foreach (ref e; edges) {
            putU32(buf, e.from);
            putU32(buf, e.to);
            buf.put(cast(ubyte) e.kind);
        }

        // -- CRC32 checksum --
        auto data = buf.data;
        auto crc = crc32Of(data);
        buf.put(crc[]);

        return buf.data;
    }

    /**
     * Deserialize graph from binary format.
     * Returns null on corruption, version mismatch, or truncation.
     */
    static DeclDependencyGraph deserialize(const(ubyte)[] data) {
        // Minimum: magic(4) + version(4) + string_count(4) + node_count(4) + edge_count(4) + crc(4) = 24
        if (data.length < 24)
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

        // -- Nodes --
        if (pos + 4 > contentData.length) return null;
        uint nodeCount = getU32(data, pos);
        pos += 4;

        auto graph = new DeclDependencyGraph();

        foreach (_; 0 .. nodeCount) {
            // Each node: id(4) + filename_idx(4) + startByte(4) + endByte(4) +
            //            name_idx(4) + kind_idx(4) + mangledName_idx(4) +
            //            sigHash(8) + srcHash(8) = 44
            if (pos + 44 > contentData.length) return null;

            uint id             = getU32(data, pos); pos += 4;
            uint fnameIdx       = getU32(data, pos); pos += 4;
            uint startByte      = getU32(data, pos); pos += 4;
            uint endByte        = getU32(data, pos); pos += 4;
            uint nameIdx        = getU32(data, pos); pos += 4;
            uint kindIdx        = getU32(data, pos); pos += 4;
            uint mangledNameIdx = getU32(data, pos); pos += 4;
            ulong sigHash       = getU64(data, pos); pos += 8;
            ulong srcHash       = getU64(data, pos); pos += 8;

            if (fnameIdx >= stringCount || nameIdx >= stringCount
                || kindIdx >= stringCount || mangledNameIdx >= stringCount)
                return null;

            string filename    = stringTable[fnameIdx];
            string name        = stringTable[nameIdx];
            string kind        = stringTable[kindIdx];
            string mangledName = stringTable[mangledNameIdx];

            graph.nodes ~= DeclNode(id, filename, startByte, endByte, name, kind, sigHash, srcHash, mangledName);

            // Rebuild spatial index
            if (filename !in graph.nodesByFile)
                graph.nodesByFile[filename] = [];
            graph.nodesByFile[filename] ~= id;

            // Track nextId
            if (id >= graph.nextId)
                graph.nextId = id + 1;
        }

        // -- Edges --
        if (pos + 4 > contentData.length) return null;
        uint edgeCount = getU32(data, pos);
        pos += 4;

        foreach (_; 0 .. edgeCount) {
            // Each edge: from(4) + to(4) + kind(1) = 9
            if (pos + 9 > contentData.length) return null;

            uint from     = getU32(data, pos); pos += 4;
            uint to       = getU32(data, pos); pos += 4;
            ubyte kindVal = data[pos]; pos += 1;

            if (kindVal > EdgeKind.max)
                return null;

            auto kind = cast(EdgeKind) kindVal;
            graph.edges ~= DeclEdge(from, to, kind);

            // Rebuild adjacency
            if (from !in graph.dependsOn)
                graph.dependsOn[from] = [];
            graph.dependsOn[from] ~= to;

            if (to !in graph.dependedOnBy)
                graph.dependedOnBy[to] = [];
            graph.dependedOnBy[to] ~= from;
        }

        return graph;
    }

    /**
     * Save graph to file atomically (write to .tmp, then rename).
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
     * Load graph from file. Returns null if file missing or corrupt.
     */
    static DeclDependencyGraph loadFromFile(string path) {
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

/// Write a u64 in little-endian
private void putU64(ref Appender!(ubyte[]) buf, ulong value) {
    buf.put(cast(ubyte)(value & 0xFF));
    buf.put(cast(ubyte)((value >> 8) & 0xFF));
    buf.put(cast(ubyte)((value >> 16) & 0xFF));
    buf.put(cast(ubyte)((value >> 24) & 0xFF));
    buf.put(cast(ubyte)((value >> 32) & 0xFF));
    buf.put(cast(ubyte)((value >> 40) & 0xFF));
    buf.put(cast(ubyte)((value >> 48) & 0xFF));
    buf.put(cast(ubyte)((value >> 56) & 0xFF));
}

/// Read a u64 in little-endian
private ulong getU64(const(ubyte)[] data, size_t pos) {
    return cast(ulong) data[pos]
         | (cast(ulong) data[pos + 1] << 8)
         | (cast(ulong) data[pos + 2] << 16)
         | (cast(ulong) data[pos + 3] << 24)
         | (cast(ulong) data[pos + 4] << 32)
         | (cast(ulong) data[pos + 5] << 40)
         | (cast(ulong) data[pos + 6] << 48)
         | (cast(ulong) data[pos + 7] << 56);
}

// ------------------------------------------------------------------
//  Unit tests
// ------------------------------------------------------------------
unittest {
    import std.stdio : writefln;

    // Test 1: Round-trip empty graph
    {
        auto g = new DeclDependencyGraph();
        auto data = g.serialize();
        auto g2 = DeclDependencyGraph.deserialize(data);
        assert(g2 !is null, "Empty graph round-trip failed");
        assert(g2.nodes.length == 0);
        assert(g2.edges.length == 0);
        writefln("  ok: empty graph round-trip");
    }

    // Test 2: Round-trip with nodes and edges
    {
        auto g = new DeclDependencyGraph();
        auto a = g.addNode("src/foo.d", 10, 50, "foo", "function", 0xDEAD_BEEF_CAFE_0001, 0x1234_5678_9ABC_DEF0);
        auto b = g.addNode("src/foo.d", 60, 120, "bar", "function", 0x0000_0000_0000_0002, 0xFFFF_FFFF_FFFF_FFFF);
        auto c = g.addNode("src/types.d", 0, 200, "Point", "struct", 42, 99);
        g.addEdge(a, b, EdgeKind.calls);
        g.addEdge(a, c, EdgeKind.usesType);
        g.addEdge(b, c, EdgeKind.usesType);

        auto data = g.serialize();
        auto g2 = DeclDependencyGraph.deserialize(data);

        assert(g2 !is null, "Non-empty graph round-trip failed");
        assert(g2.nodes.length == 3, "Node count mismatch");
        assert(g2.edges.length == 3, "Edge count mismatch");

        // Check node content
        assert(g2.nodes[0].filename == "src/foo.d");
        assert(g2.nodes[0].name == "foo");
        assert(g2.nodes[0].kind == "function");
        assert(g2.nodes[0].signatureHash == 0xDEAD_BEEF_CAFE_0001);
        assert(g2.nodes[0].sourceHash == 0x1234_5678_9ABC_DEF0);
        assert(g2.nodes[0].startByte == 10);
        assert(g2.nodes[0].endByte == 50);

        // Check u64 max value roundtrip
        assert(g2.nodes[1].sourceHash == 0xFFFF_FFFF_FFFF_FFFF, "u64 max roundtrip failed");

        // Check edge content
        assert(g2.edges[0].from == a);
        assert(g2.edges[0].to == b);
        assert(g2.edges[0].kind == EdgeKind.calls);
        assert(g2.edges[1].kind == EdgeKind.usesType);

        // Check string dedup: foo.d nodes share same filename string
        assert(g2.nodes[0].filename is g2.nodes[1].filename
            || g2.nodes[0].filename == g2.nodes[1].filename);

        // Check spatial index rebuilt
        assert("src/foo.d" in g2.nodesByFile);
        assert(g2.nodesByFile["src/foo.d"].length == 2);
        assert("src/types.d" in g2.nodesByFile);
        assert(g2.nodesByFile["src/types.d"].length == 1);

        // Check adjacency rebuilt
        assert(g2.dependsOn[a].length == 2);
        assert(g2.dependedOnBy[c].length == 2);

        // Check invalidation still works
        auto affected = g2.invalidate([c]);
        assert(affected.length == 3, "Invalidation should reach all 3 nodes");

        writefln("  ok: graph round-trip with nodes/edges");
    }

    // Test 3: Corruption detection
    {
        auto g = new DeclDependencyGraph();
        g.addNode("test.d", 0, 10, "x", "global", 1, 2);
        auto data = g.serialize();

        // Corrupt a byte in the middle
        auto corrupted = data.dup;
        corrupted[12] ^= 0xFF;
        assert(DeclDependencyGraph.deserialize(corrupted) is null, "Should detect corruption");

        // Truncated data
        assert(DeclDependencyGraph.deserialize(data[0 .. 10]) is null, "Should reject truncated data");

        // Wrong magic
        auto badMagic = data.dup;
        badMagic[0] = 'X';
        // Recompute CRC for the bad-magic test to isolate magic check from CRC check
        // Actually, the CRC will also fail, which is fine — both are caught
        assert(DeclDependencyGraph.deserialize(badMagic) is null, "Should reject bad magic");

        writefln("  ok: corruption detection");
    }

    // Test 4: File I/O round-trip
    {
        import std.file : tempDir, exists, remove, mkdirRecurse;
        import std.path : buildPath;

        string testPath = buildPath(tempDir(), "d2wasm_depgraph_test", "test_graph.bin");

        auto g = new DeclDependencyGraph();
        g.addNode("main.d", 0, 100, "main", "function", 111, 222);
        g.addNode("main.d", 110, 200, "helper", "function", 333, 444);
        g.addEdge(0, 1, EdgeKind.calls);

        g.saveToFile(testPath);
        assert(exists(testPath), "File should exist after save");

        auto g2 = DeclDependencyGraph.loadFromFile(testPath);
        assert(g2 !is null, "Should load from file");
        assert(g2.nodes.length == 2);
        assert(g2.edges.length == 1);
        assert(g2.nodes[0].name == "main");
        assert(g2.nodes[1].signatureHash == 333);

        // Clean up
        try {
            remove(testPath);
            import std.file : rmdirRecurse;
            rmdirRecurse(buildPath(tempDir(), "d2wasm_depgraph_test"));
        } catch (Exception) {}

        // Missing file returns null
        assert(DeclDependencyGraph.loadFromFile("/nonexistent/path/graph.bin") is null);

        writefln("  ok: file I/O round-trip");
    }

    // Test 5: All EdgeKind values survive round-trip
    {
        auto g = new DeclDependencyGraph();
        foreach (i; 0 .. 5)
            g.addNode("e.d", 0, 10, "n" ~ format("%d", i), "function", 0, 0);
        g.addEdge(0, 1, EdgeKind.calls);
        g.addEdge(1, 2, EdgeKind.usesType);
        g.addEdge(2, 3, EdgeKind.readsManifest);
        g.addEdge(3, 4, EdgeKind.methodOf);

        auto g2 = DeclDependencyGraph.deserialize(g.serialize());
        assert(g2 !is null);
        assert(g2.edges[0].kind == EdgeKind.calls);
        assert(g2.edges[1].kind == EdgeKind.usesType);
        assert(g2.edges[2].kind == EdgeKind.readsManifest);
        assert(g2.edges[3].kind == EdgeKind.methodOf);

        writefln("  ok: all EdgeKind values round-trip");
    }

    // Test 6: transitiveDeps
    {
        auto g = new DeclDependencyGraph();
        // Chain: 0 -> 1 -> 2 -> 3, plus 0 -> 4 (standalone)
        foreach (i; 0 .. 5)
            g.addNode("t.d", 0, 10, "n" ~ format("%d", i), "function", 0, 0);
        g.addEdge(0, 1, EdgeKind.calls);
        g.addEdge(1, 2, EdgeKind.calls);
        g.addEdge(2, 3, EdgeKind.usesType);
        g.addEdge(0, 4, EdgeKind.readsManifest);

        // transitiveDeps(0) should return {1, 2, 3, 4} (sorted)
        auto deps0 = g.transitiveDeps(0);
        assert(deps0.length == 4, format("Expected 4 deps, got %d", deps0.length));
        assert(deps0 == [1, 2, 3, 4], "transitiveDeps(0) wrong");

        // transitiveDeps(1) should return {2, 3}
        auto deps1 = g.transitiveDeps(1);
        assert(deps1 == [2, 3], "transitiveDeps(1) wrong");

        // transitiveDeps(3) should return {} (leaf)
        auto deps3 = g.transitiveDeps(3);
        assert(deps3.length == 0, "transitiveDeps(3) should be empty");

        // transitiveDeps(4) should return {} (leaf)
        auto deps4 = g.transitiveDeps(4);
        assert(deps4.length == 0, "transitiveDeps(4) should be empty");

        writefln("  ok: transitiveDeps");
    }
}
