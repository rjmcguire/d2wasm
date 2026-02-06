// Milestone 101: Cache Entry Format for Incremental Compilation
//
// This milestone adds:
// - CacheEntry struct with memberName, sourceHash, dependencies, wasmBytes
// - Binary serialization format with length prefix and CRC32 checksum
// - Deserialization with corruption detection
// - SourceHash computation using MurmurHash3
//
// Tested via unittest in src/cache/entry.d:
// - Round-trip serialization
// - Empty dependencies handling
// - Corruption detection (checksum validation)
// - Hash consistency (same input → same hash)
// - Source-based hashing
// - Tree-sitter S-expression availability

int main() { return 0; }
