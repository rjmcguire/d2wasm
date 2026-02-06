// Milestone 113: FileWatcher abstraction with debouncing
//
// Provides:
// - IFileWatcher interface for platform-agnostic watching
// - DebouncedWatcher wrapper that collects rapid events
// - FSEventsWatcher implementation for macOS
// - createWatcher() and createDebouncedWatcher() factory functions
//
// Debouncing:
// - Collects change events within a 200ms window
// - Deduplicates repeated paths
// - Fires single callback after quiet period
//
// Tested via unittests in watcher.watcher and watcher.fsevents_watcher

int main() { return 0; }
