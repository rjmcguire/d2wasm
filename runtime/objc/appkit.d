// ObjC AppKit framework bindings
// Import with: import objc.appkit;

module objc.appkit;

import objc.foundation;

pragma(lib, "/System/Library/Frameworks/Cocoa.framework/Cocoa");

struct NSPoint { double x; double y; }
struct NSSize { double width; double height; }
struct NSRect { double x; double y; double width; double height; }

extern(Objective-C)
interface NSApplication {
    static NSApplication sharedApplication();
    void setActivationPolicy(long policy);
    void activateIgnoringOtherApps(int flag);
    NSEvent nextEventMatchingMask(long mask, NSDate untilDate, NSString inMode, int dequeue)
        @selector("nextEventMatchingMask:untilDate:inMode:dequeue:");
    void sendEvent(NSEvent event);
    void updateWindows();
}

extern(Objective-C)
interface NSWindow {
    static NSWindow alloc();
    NSWindow initWithContentRect(NSRect rect, long styleMask, long backing, int defer_)
        @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title);
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
