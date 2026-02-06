// Milestone 104: Main Database for Incremental Compilation Cache
//
// This milestone adds:
// - MainDatabase class with append-only storage
// - In-memory index mapping member names to file offsets
// - lookup() - retrieve cache entry by member name
// - append() - add new entries (newer entries shadow older ones)
// - mergeFromStaging() - import entries from staging files
// - compact() - rewrite file with only latest entries
//
// File format: D2WC magic + version + serialized CacheEntry records
//
// Tested via unittest in src/cache/maindb.d

int main() { return 0; }
