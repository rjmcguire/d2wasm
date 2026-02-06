/**
 * File Watcher Interface and Factory
 * 
 * Provides a cross-platform interface for watching file system changes
 * with built-in debouncing.
 */
module watcher.watcher;

import std.datetime;
import core.thread;
import core.sync.mutex;

/// Callback type for file change notifications
alias FileChangedCallback = void delegate(string[] changedPaths);

/**
 * File watcher interface.
 * Platform implementations provide native file system notifications.
 */
interface IFileWatcher {
    /// Add a path to watch (file or directory)
    void addPath(string path);
    
    /// Remove a path from watching
    void removePath(string path);
    
    /// Start watching (blocks until stop() is called)
    void start();
    
    /// Stop watching
    void stop();
    
    /// Check if currently watching
    bool isRunning() const;
}

/**
 * Debounced file watcher wrapper.
 * Collects rapid change events and fires callback after quiet period.
 */
class DebouncedWatcher : IFileWatcher {
    private {
        IFileWatcher inner;
        FileChangedCallback callback;
        Duration debounceTime;
        
        // Debounce state
        Mutex mutex;
        string[] pendingPaths;
        MonoTime lastEvent;
        bool hasEvents;
        Thread debounceThread;
        bool running;
    }
    
    /**
     * Create a debounced watcher.
     * 
     * Params:
     *   inner = The underlying platform watcher
     *   callback = Called when files change (after debounce)
     *   debounceMs = Debounce window in milliseconds (default: 200)
     */
    this(IFileWatcher inner, FileChangedCallback callback, uint debounceMs = 200) {
        this.inner = inner;
        this.callback = callback;
        this.debounceTime = dur!"msecs"(debounceMs);
        this.mutex = new Mutex();
    }
    
    void addPath(string path) {
        inner.addPath(path);
    }
    
    void removePath(string path) {
        inner.removePath(path);
    }
    
    void start() {
        running = true;
        
        // Start debounce thread
        debounceThread = new Thread(&debounceLoop);
        debounceThread.start();
        
        // Start inner watcher (blocks)
        inner.start();
    }
    
    void stop() {
        running = false;
        inner.stop();
        if (debounceThread !is null) {
            debounceThread.join();
        }
    }
    
    bool isRunning() const {
        return running;
    }
    
    /// Called by platform watcher when files change
    void onRawChange(string[] paths) {
        synchronized(mutex) {
            foreach (p; paths) {
                // Deduplicate
                import std.algorithm : canFind;
                if (!pendingPaths.canFind(p)) {
                    pendingPaths ~= p;
                }
            }
            lastEvent = MonoTime.currTime;
            hasEvents = true;
        }
    }
    
    private void debounceLoop() {
        while (running) {
            Thread.sleep(dur!"msecs"(50));  // Check every 50ms
            
            synchronized(mutex) {
                if (hasEvents) {
                    auto elapsed = MonoTime.currTime - lastEvent;
                    if (elapsed >= debounceTime) {
                        // Debounce period passed, fire callback
                        if (pendingPaths.length > 0 && callback !is null) {
                            auto paths = pendingPaths.dup;
                            pendingPaths.length = 0;
                            hasEvents = false;
                            
                            // Call outside synchronized block
                            mutex.unlock();
                            try {
                                callback(paths);
                            } catch (Exception e) {
                                // Don't let callback errors stop watcher
                            }
                            mutex.lock();
                        }
                    }
                }
            }
        }
    }
}

/**
 * Create a platform-appropriate file watcher.
 */
IFileWatcher createWatcher() {
    version(OSX) {
        import watcher.fsevents_watcher : FSEventsWatcher;
        return new FSEventsWatcher();
    } else version(linux) {
        // TODO: Implement inotify watcher
        assert(false, "Linux watcher not yet implemented");
    } else {
        assert(false, "No file watcher available for this platform");
    }
}

/**
 * Create a debounced file watcher.
 */
DebouncedWatcher createDebouncedWatcher(FileChangedCallback callback, uint debounceMs = 200) {
    auto inner = createWatcher();
    return new DebouncedWatcher(inner, callback, debounceMs);
}

//==============================================================================
// Unit Tests
//==============================================================================

unittest {
    import std.stdio : writeln;
    
    // Test debounce logic (without actual file system)
    string[] receivedPaths;
    int callCount = 0;
    
    // Create a mock watcher for testing
    static class MockWatcher : IFileWatcher {
        void addPath(string path) {}
        void removePath(string path) {}
        void start() {}
        void stop() {}
        bool isRunning() const { return false; }
    }
    
    auto mock = new MockWatcher();
    auto debounced = new DebouncedWatcher(mock, (paths) {
        receivedPaths = paths.dup;
        callCount++;
    }, 100);
    
    // Simulate rapid events
    debounced.onRawChange(["file1.d"]);
    debounced.onRawChange(["file2.d"]);
    debounced.onRawChange(["file1.d"]);  // Duplicate
    
    // Should have 2 unique pending paths
    assert(debounced.pendingPaths.length == 2);
    
    writeln("✓ FileWatcher debounce deduplication test passed");
}
