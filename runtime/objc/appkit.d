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
    id nextEventMatchingMask(long mask, id untilDate, id inMode, int dequeue)
        @selector("nextEventMatchingMask:untilDate:inMode:dequeue:");
    void sendEvent(id event) @selector("sendEvent:");
    void updateWindows();
}

extern(Objective-C)
interface NSWindow {
    static NSWindow alloc();
    NSWindow initWithContentRect(NSRect rect, long styleMask, long backing, int defer_)
        @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(id title) @selector("setTitle:");
    void makeKeyAndOrderFront(id sender);
    id contentView();
    void setDelegate(id del);
}

extern(Objective-C)
interface NSView {
    static NSView alloc();
    NSView initWithFrame(NSRect frame_);
    void setWantsLayer(int flag);
    void setLayer(id layer);
    void setAutoresizingMask(long mask);
    void addSubview(id view);
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
