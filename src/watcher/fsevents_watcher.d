/**
 * FSEvents File Watcher Implementation
 * 
 * macOS native file system watcher using FSEvents API.
 */
module watcher.fsevents_watcher;

version(OSX):

import watcher.watcher : IFileWatcher;
import watcher.fsevents;
import core.thread;
import std.string : toStringz, fromStringz;

/**
 * macOS FSEvents-based file watcher.
 */
class FSEventsWatcher : IFileWatcher {
    private {
        string[] watchPaths;
        FSEventStreamRef stream;
        CFRunLoopRef runLoop;
        Thread runLoopThread;
        bool running;
        
        // Callback for change notifications
        void delegate(string[]) changeCallback;
    }
    
    /// Set callback for change notifications
    void setCallback(void delegate(string[]) callback) {
        this.changeCallback = callback;
    }
    
    void addPath(string path) {
        import std.path : absolutePath;
        watchPaths ~= absolutePath(path);
    }
    
    void removePath(string path) {
        import std.algorithm : remove, countUntil;
        import std.path : absolutePath;
        auto absPath = absolutePath(path);
        auto idx = watchPaths.countUntil(absPath);
        if (idx >= 0) {
            watchPaths = watchPaths.remove(idx);
        }
    }
    
    void start() {
        if (running) return;
        if (watchPaths.length == 0) return;
        
        running = true;
        
        // Create path array
        auto pathArray = createPathArray(watchPaths);
        if (pathArray is null) return;
        
        // Create context with this pointer
        FSEventStreamContext context;
        context.info = cast(void*)this;
        
        // Create stream
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            &fseventsCallback,
            &context,
            pathArray,
            kFSEventStreamEventIdSinceNow,
            0.1,  // 100ms latency
            FSEventStreamCreateFlags.FileEvents | FSEventStreamCreateFlags.NoDefer
        );
        
        CFRelease(pathArray);
        
        if (stream is null) {
            running = false;
            return;
        }
        
        // Run in current thread
        runLoop = CFRunLoopGetCurrent();
        FSEventStreamScheduleWithRunLoop(stream, runLoop, kCFRunLoopDefaultMode);
        
        if (!FSEventStreamStart(stream)) {
            FSEventStreamInvalidate(stream);
            FSEventStreamRelease(stream);
            stream = null;
            running = false;
            return;
        }
        
        // Run the run loop (blocks)
        CFRunLoopRun();
    }
    
    void stop() {
        if (!running) return;
        running = false;
        
        if (stream !is null) {
            FSEventStreamStop(stream);
            FSEventStreamInvalidate(stream);
            FSEventStreamRelease(stream);
            stream = null;
        }
        
        if (runLoop !is null) {
            CFRunLoopStop(runLoop);
        }
    }
    
    bool isRunning() const {
        return running;
    }
    
    private void handleEvents(string[] paths) {
        if (changeCallback !is null) {
            changeCallback(paths);
        }
    }
}

/// C callback function for FSEvents
private extern(C) void fseventsCallback(
    FSEventStreamRef streamRef,
    void* clientCallBackInfo,
    size_t numEvents,
    void* eventPaths,
    const(FSEventStreamEventFlags)* eventFlags,
    const(FSEventStreamEventId)* eventIds
) nothrow {
    try {
        auto watcher = cast(FSEventsWatcher)clientCallBackInfo;
        if (watcher is null) return;
        
        // eventPaths is CFArrayRef of CFStringRef
        auto pathArray = cast(CFArrayRef)eventPaths;
        auto count = CFArrayGetCount(pathArray);
        
        string[] paths;
        foreach (i; 0 .. count) {
            auto cfStr = cast(CFStringRef)CFArrayGetValueAtIndex(pathArray, i);
            auto path = fromCFString(cfStr);
            if (path !is null) {
                paths ~= path;
            }
        }
        
        if (paths.length > 0) {
            watcher.handleEvents(paths);
        }
    } catch (Exception e) {
        // Ignore exceptions in callback
    }
}

//==============================================================================
// Unit Tests
//==============================================================================

unittest {
    import std.stdio : writeln;
    
    // Basic instantiation test
    auto watcher = new FSEventsWatcher();
    assert(watcher !is null);
    assert(!watcher.isRunning());
    
    watcher.addPath(".");
    assert(watcher.watchPaths.length == 1);
    
    writeln("✓ FSEventsWatcher instantiation test passed");
}
