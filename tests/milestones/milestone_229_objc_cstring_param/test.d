// Milestone 229: Transparent C string passing to ObjC methods
//
// Tests that string literals can be passed directly to extern(Objective-C)
// interface methods that take char* parameters. The compiler emits a
// null-terminated CString in the data section and the FFI trampoline
// converts the WASM linear memory offset to a native pointer (ARG_PTR).

pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

extern(Objective-C)
interface NSString {
    static NSString stringWithUTF8String(char* cstr) @selector("stringWithUTF8String:");
    long length() @selector("length");
}

int main() {
    // Basic: pass a string literal directly as char*
    NSString hello = NSString.stringWithUTF8String("hello");
    if (cast(long)hello == 0) return 1;
    if (hello.length() != 5) return 2;

    // UTF-8 string via \x hex escapes: "D → WASM" (→ = U+2192 = \xe2\x86\x92)
    NSString arrow = NSString.stringWithUTF8String("D \xe2\x86\x92 WASM");
    if (cast(long)arrow == 0) return 3;
    // NSString.length counts UTF-16 code units: "D → WASM" = 8
    if (arrow.length() != 8) return 4;

    // Empty string
    NSString empty = NSString.stringWithUTF8String("");
    if (cast(long)empty == 0) return 5;
    if (empty.length() != 0) return 6;

    return 42;
}
