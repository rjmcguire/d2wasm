// Milestone 266: Shared ObjC binding modules
//
// Uses `import objc.foundation;` instead of redeclaring interfaces locally.
// The pragma(lib) in the binding module handles framework linking.

import objc.foundation;

int main() {
    // Use NSString from the shared binding — no local interface needed
    NSString s = NSString.stringWithUTF8String("hello world!!".toStringz());
    long len = s.length();
    if (len != 13) return 1;

    // Use NSMutableString from the shared binding
    NSMutableString ms = NSMutableString.alloc().initWithUTF8String("count: ".toStringz());
    NSString suffix = NSString.stringWithUTF8String("42".toStringz());
    ms.appendString(suffix);
    long totalLen = ms.length();
    if (totalLen != 9) return 2;

    return 42;
}
