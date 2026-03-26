// Milestone 265: Auto-derived ObjC selectors
//
// When @selector is omitted on extern(Objective-C) methods, the selector
// is derived from the D method name: "name" for 0 params, "name:" for 1 param.
// Multi-param methods with distinct selector parts still need explicit @selector.

pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

extern(Objective-C)
interface NSObject {
    // Auto-derived: "alloc" (0 params)
    static NSObject alloc();
    // Auto-derived: "init" (0 params)
    NSObject init_() @selector("init");  // init_ needs explicit (trailing underscore)
}

extern(Objective-C)
interface NSString {
    // Auto-derived: "stringWithUTF8String:" (1 param)
    static NSString stringWithUTF8String(char* cstr);
    // Auto-derived: "length" (0 params)
    long length();
}

extern(Objective-C)
interface NSMutableString {
    static NSMutableString alloc();
    // Auto-derived: "initWithUTF8String:" (1 param)
    NSMutableString initWithUTF8String(char* cstr);
    // Auto-derived: "appendString:" (1 param)
    void appendString(NSString str);
    long length();
}

int main() {
    // Test auto-derived selectors: 0-param and 1-param
    NSString s = NSString.stringWithUTF8String("hello".toStringz());
    long len = s.length();
    if (len != 5) return 1;

    // Test auto-derived on mutable string with append
    NSMutableString ms = NSMutableString.alloc().initWithUTF8String("hello".toStringz());
    NSString suffix = NSString.stringWithUTF8String(" world".toStringz());
    ms.appendString(suffix);
    long totalLen = ms.length();
    if (totalLen != 11) return 2;

    // 5 + 11 + 26 = 42
    return 42;
}
