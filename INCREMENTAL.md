# Incremental Compilation Design

## Overview

Function/module-member level caching with append-only storage and process-per-module parallelism.

## Storage Architecture

```
.d2wasm-cache/
├── main.db              # Compacted, stable, mmap'd readonly during compilation
└── staging/
    ├── foo.pending      # Module foo's new entries
    ├── bar.pending      # Module bar's new entries
    └── ...
```

**Main.db**: Append-only with compaction. Only written during controlled merge.

**Staging files**: Written by child processes during compilation. Merged into main.db after successful compile. Deleted on crash/corruption (safe recovery).

## Cache Entry Format

```
[length: u32]
[member_name: length-prefixed string]
[source_hash: 32 bytes]
[dependency_count: u32]
[dependencies: array of length-prefixed strings]
[dependency_hashes: array of 32-byte hashes]
[wasm_length: u32]
[wasm_bytes: raw bytes]
[checksum: u32]
```

## Hashing Strategy

Use tree-sitter's `ts_node_string()` S-expression output. Hash the S-expression.
- Whitespace/formatting changes don't affect hash
- Only structural/semantic changes cause recompilation

## Dependency Tracking

Each cache entry stores transitive closure of referenced symbols:
- Function calls
- Type references (structs, enums)
- Global variables

Invalidation: if source_hash OR any dependency_hash changes → recompile.

## Process Model

**Orchestrator (parent):**
1. mmap main.db readonly, build index
2. Determine which modules need recompiling
3. Spawn children in parallel:
   `d2wasm --compile-module=foo --cache=main.db --staging=staging/foo.pending`
4. Collect JSON responses from children
5. Validate + merge staging files into main.db

**Child (d2wasm --compile-module):**
1. mmap main.db readonly (for dependency cache hits)
2. Compile module members, check cache for each
3. Write staging file with new/updated entries
4. Output JSON to stdout:
   ```json
   {
     "module": "foo",
     "stagingFile": "staging/foo.pending",
     "compiled": ["func1", "func2"],
     "cacheHits": ["func3"],
     "success": true
   }
   ```
5. Exit

## Milestones

1. ✅ **milestone_101** Cache entry format (serialize/deserialize, round-trip test)
2. ✅ **milestone_102** Source hashing + Dependency extraction
3. Staging file write
4. Staging file read + validate
5. Main.db merge
6. Cache hit detection
7. Compile with cache (skip cached members)
8. Child process mode (--compile-module flag + JSON output)
9. Orchestrator (spawn children, merge results)
10. Compaction
