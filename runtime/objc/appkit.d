// ObjC AppKit framework bindings
// Import with: import objc.appkit;

module objc.appkit;

pragma(lib, "/System/Library/Frameworks/Cocoa.framework/Cocoa");

struct NSPoint { double x; double y; }
struct NSSize { double width; double height; }
struct NSRect { double x; double y; double width; double height; }

extern(Objective-C)
interface NSApplication {
    static NSApplication sharedApplication();
    void setActivationPolicy(long policy);
    void activateIgnoringOtherApps(int flag);
    long nextEventMatchingMask(long mask, long untilDate, long inMode, int dequeue)
        @selector("nextEventMatchingMask:untilDate:inMode:dequeue:");
    void sendEvent(long event) @selector("sendEvent:");
    void updateWindows();
}

extern(Objective-C)
interface NSWindow {
    static NSWindow alloc();
    NSWindow initWithContentRect(NSRect rect, long styleMask, long backing, int defer_)
        @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(long title) @selector("setTitle:");
    void makeKeyAndOrderFront(long sender);
    long contentView();
    void setDelegate(long del);
}

extern(Objective-C)
interface NSView {
    static NSView alloc();
    NSView initWithFrame(NSRect frame_);
    void setWantsLayer(int flag);
    void setLayer(long layer);
    void setAutoresizingMask(long mask);
    void addSubview(long view);
    NSRect bounds();
}

extern(Objective-C)
interface NSEvent {
    NSPoint locationInWindow();
}

extern(Objective-C)
interface NSDate {
    static NSDate dateWithTimeIntervalSinceNow(double secs);
}
