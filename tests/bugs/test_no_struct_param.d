// Struct return only, no struct params — avoid valueWithPoint entirely
pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

struct MyPoint { double x; double y; }
struct MyRect { double x; double y; double w; double h; }

extern(Objective-C)
interface NSObject {
    static NSObject alloc() @selector("alloc");
    NSObject init_() @selector("init");
}

extern(Objective-C)
interface NSProcessInfo {
    static NSProcessInfo processInfo() @selector("processInfo");
    long processIdentifier() @selector("processIdentifier");
}

// Use NSString length to verify an object is alive
extern(Objective-C)
interface NSString {
    static NSString stringWithUTF8String(long cstr) @selector("stringWithUTF8String:");
    long length() @selector("length");
}

extern(C) long metal_get_cstr_title();

int main() {
    // Two struct locals
    MyRect a;
    a.x = 1.0; a.y = 2.0; a.w = 3.0; a.h = 4.0;

    MyRect b;
    b.x = 5.0; b.y = 6.0; b.w = 7.0; b.h = 8.0;

    if (a.x != 1.0) return 1;
    if (b.x != 5.0) return 2;

    // Simple ObjC call (no struct) to verify basic ObjC works
    NSProcessInfo info = NSProcessInfo.processInfo();
    long pid = info.processIdentifier();
    if (pid == 0) return 3;

    return 42;
}
