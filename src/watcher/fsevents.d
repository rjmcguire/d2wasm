/**
 * macOS FSEvents C Bindings
 * 
 * Provides D bindings for the CoreServices FSEvents API for native
 * file system change notifications.
 */
module watcher.fsevents;

version(OSX):

import core.stdc.stdint;

//==============================================================================
// CoreFoundation Types
//==============================================================================

alias CFIndex = long;
alias CFTimeInterval = double;
alias CFAbsoluteTime = double;
alias CFAllocatorRef = void*;
alias CFStringRef = void*;
alias CFArrayRef = void*;
alias CFRunLoopRef = void*;
alias CFDictionaryRef = void*;

/// Constant for default allocator
enum CFAllocatorRef kCFAllocatorDefault = null;

/// Constant for default run loop mode
__gshared CFStringRef kCFRunLoopDefaultMode;

//==============================================================================
// FSEvents Types
//==============================================================================

alias FSEventStreamRef = void*;
alias FSEventStreamEventId = ulong;

/// Flags for event stream creation
enum FSEventStreamCreateFlags : uint {
    None = 0x00000000,
    UseCFTypes = 0x00000001,
    NoDefer = 0x00000002,
    WatchRoot = 0x00000004,
    IgnoreSelf = 0x00000008,
    FileEvents = 0x00000010,
    MarkSelf = 0x00000020,
    UseExtendedData = 0x00000040,
}

/// Event flags passed to callback
enum FSEventStreamEventFlags : uint {
    None = 0x00000000,
    MustScanSubDirs = 0x00000001,
    UserDropped = 0x00000002,
    KernelDropped = 0x00000004,
    EventIdsWrapped = 0x00000008,
    HistoryDone = 0x00000010,
    RootChanged = 0x00000020,
    Mount = 0x00000040,
    Unmount = 0x00000080,
    ItemCreated = 0x00000100,
    ItemRemoved = 0x00000200,
    ItemInodeMetaMod = 0x00000400,
    ItemRenamed = 0x00000800,
    ItemModified = 0x00001000,
    ItemFinderInfoMod = 0x00002000,
    ItemChangeOwner = 0x00004000,
    ItemXattrMod = 0x00008000,
    ItemIsFile = 0x00010000,
    ItemIsDir = 0x00020000,
    ItemIsSymlink = 0x00040000,
    OwnEvent = 0x00080000,
    ItemIsHardlink = 0x00100000,
    ItemIsLastHardlink = 0x00200000,
    ItemCloned = 0x00400000,
}

/// Callback function type
alias FSEventStreamCallback = extern(C) void function(
    FSEventStreamRef streamRef,
    void* clientCallBackInfo,
    size_t numEvents,
    void* eventPaths,
    const(FSEventStreamEventFlags)* eventFlags,
    const(FSEventStreamEventId)* eventIds
) nothrow;

/// Context structure for stream creation
struct FSEventStreamContext {
    CFIndex version_ = 0;
    void* info = null;
    void* retain = null;
    void* release = null;
    void* copyDescription = null;
}

//==============================================================================
// CoreFoundation Functions
//==============================================================================

extern(C) nothrow @nogc {
    /// Get the current thread's run loop
    CFRunLoopRef CFRunLoopGetCurrent();
    
    /// Run the current run loop
    void CFRunLoopRun();
    
    /// Stop a run loop
    void CFRunLoopStop(CFRunLoopRef rl);
    
    /// Create a CFString from a C string
    CFStringRef CFStringCreateWithCString(
        CFAllocatorRef alloc,
        const(char)* cStr,
        uint encoding
    );
    
    /// Release a CoreFoundation object
    void CFRelease(void* cf);
    
    /// Create a CFArray from C array
    CFArrayRef CFArrayCreate(
        CFAllocatorRef allocator,
        const(void*)* values,
        CFIndex numValues,
        void* callBacks
    );
    
    /// Get CFArray count
    CFIndex CFArrayGetCount(CFArrayRef theArray);
    
    /// Get CFArray value at index
    const(void)* CFArrayGetValueAtIndex(CFArrayRef theArray, CFIndex idx);
    
    /// Get C string from CFString
    bool CFStringGetCString(
        CFStringRef theString,
        char* buffer,
        CFIndex bufferSize,
        uint encoding
    );
}

/// UTF-8 encoding constant
enum uint kCFStringEncodingUTF8 = 0x08000100;

//==============================================================================
// FSEvents Functions
//==============================================================================

extern(C) nothrow @nogc {
    /// Create an FSEvent stream
    FSEventStreamRef FSEventStreamCreate(
        CFAllocatorRef allocator,
        FSEventStreamCallback callback,
        FSEventStreamContext* context,
        CFArrayRef pathsToWatch,
        FSEventStreamEventId sinceWhen,
        CFTimeInterval latency,
        FSEventStreamCreateFlags flags
    );
    
    /// Schedule stream with run loop
    void FSEventStreamScheduleWithRunLoop(
        FSEventStreamRef streamRef,
        CFRunLoopRef runLoop,
        CFStringRef runLoopMode
    );
    
    /// Start the stream
    bool FSEventStreamStart(FSEventStreamRef streamRef);
    
    /// Stop the stream
    void FSEventStreamStop(FSEventStreamRef streamRef);
    
    /// Invalidate the stream
    void FSEventStreamInvalidate(FSEventStreamRef streamRef);
    
    /// Release the stream
    void FSEventStreamRelease(FSEventStreamRef streamRef);
}

/// Special event ID meaning "start from now"
enum FSEventStreamEventId kFSEventStreamEventIdSinceNow = 0xFFFFFFFFFFFFFFFF;

//==============================================================================
// Helper Functions
//==============================================================================

/// Convert a D string to CFStringRef
CFStringRef toCFString(string s) nothrow @nogc {
    import core.stdc.string : strlen;
    // Need null-terminated string
    char[1024] buffer;
    if (s.length >= buffer.length) return null;
    buffer[0 .. s.length] = s[];
    buffer[s.length] = '\0';
    return CFStringCreateWithCString(kCFAllocatorDefault, buffer.ptr, kCFStringEncodingUTF8);
}

/// Convert CFStringRef to D string (allocates)
string fromCFString(CFStringRef cfStr) nothrow {
    if (cfStr is null) return null;
    char[1024] buffer;
    if (CFStringGetCString(cfStr, buffer.ptr, buffer.length, kCFStringEncodingUTF8)) {
        import core.stdc.string : strlen;
        size_t len = strlen(buffer.ptr);
        return buffer[0 .. len].idup;
    }
    return null;
}

/// Create CFArray of paths from D string array
CFArrayRef createPathArray(string[] paths) nothrow {
    if (paths.length == 0) return null;
    
    const(void)*[64] cfStrings;  // Max 64 paths
    size_t count = paths.length < 64 ? paths.length : 64;
    
    foreach (i; 0 .. count) {
        cfStrings[i] = cast(const(void)*)toCFString(paths[i]);
    }
    
    return CFArrayCreate(kCFAllocatorDefault, cfStrings.ptr, cast(CFIndex)count, null);
}

//==============================================================================
// Initialization
//==============================================================================

// RTLD_DEFAULT for dlsym (macOS)
private enum void* RTLD_DEFAULT = cast(void*)(-2);

private extern(C) void* dlsym(void* handle, const(char)* symbol) nothrow @nogc;

/// Initialize the module (load kCFRunLoopDefaultMode)
shared static this() {
    // Link to CoreFoundation symbol
    auto ptr = dlsym(RTLD_DEFAULT, "kCFRunLoopDefaultMode");
    if (ptr !is null) {
        kCFRunLoopDefaultMode = *cast(CFStringRef*)ptr;
    }
}

//==============================================================================
// Unit Tests
//==============================================================================

unittest {
    import std.stdio : writeln;
    
    // Test CFString conversion
    auto cfStr = toCFString("hello");
    assert(cfStr !is null, "toCFString failed");
    
    auto dStr = fromCFString(cfStr);
    assert(dStr == "hello", "fromCFString failed");
    
    CFRelease(cfStr);
    
    writeln("✓ FSEvents CFString conversion test passed");
}

unittest {
    import std.stdio : writeln;
    
    // Test path array creation
    auto paths = [".", "/tmp"];
    auto cfArray = createPathArray(paths);
    assert(cfArray !is null, "createPathArray failed");
    assert(CFArrayGetCount(cfArray) == 2, "Array count wrong");
    
    CFRelease(cfArray);
    
    writeln("✓ FSEvents path array test passed");
}
