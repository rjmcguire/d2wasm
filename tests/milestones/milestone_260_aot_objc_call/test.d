// Milestone 260: AOT ObjC symbol relocations
//
// Verifies that ObjC interface method calls compile to Mach-O binary
// with proper external symbol relocations for objc_msgSend, objc_getClass,
// and sel_registerName, and that the linked binary runs correctly.

pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

extern(Objective-C)
interface NSString {
    static NSString stringWithUTF8String(char* cstr) @selector("stringWithUTF8String:");
    long length() @selector("length");
}

int main() {
    // Static ObjC call: objc_getClass("NSString") + objc_msgSend
    NSString s = NSString.stringWithUTF8String("hello world!".toStringz());

    // Instance ObjC call: objc_msgSend on instance
    long len = s.length();

    // "hello world!" = 12 chars
    if (len != 12) return 1;

    return 42;
}
