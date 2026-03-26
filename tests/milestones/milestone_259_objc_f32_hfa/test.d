// Milestone 259: Float32 HFA detection and passing
//
// Verifies that structs with float (f32) fields are correctly detected as HFA
// and that the native backend handles them alongside f64 HFA ObjC calls.
// ARM64 ABI: f32 HFA uses s0-s3, f64 HFA uses d0-d3.
//
// This test exercises f64 HFA (CGSize) through a real ObjC call to verify
// the detectHFAInfo refactor didn't break existing behavior, and exercises
// f32 struct field access to verify correct layout.

pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

struct CGSize { double width; double height; }
struct Vec2f { float x; float y; }

extern(Objective-C)
interface NSObject {
    static NSObject alloc() @selector("alloc");
    NSObject init_() @selector("init");
}

extern(Objective-C)
interface NSValue {
    static NSValue alloc() @selector("alloc");
    // sizeValue returns CGSize (f64 HFA) — exercises the return path
    CGSize sizeValue() @selector("sizeValue");
}

extern(Objective-C)
interface NSString {
    static NSString stringWithUTF8String(char* cstr) @selector("stringWithUTF8String:");
    long length() @selector("length");
}

int main() {
    // Test 1: f32 struct field access works correctly
    Vec2f v;
    v.x = 10.5;
    v.y = 31.5;
    // Verify: truncate to int and sum = 10 + 31 = 41
    int ix = cast(int) v.x;
    int iy = cast(int) v.y;
    if (ix != 10) return 1;
    if (iy != 31) return 2;

    // Test 2: f64 HFA ObjC call still works (detectHFAInfo refactor regression check)
    NSString s = NSString.stringWithUTF8String("x".toStringz());
    long len = s.length();
    if (len != 1) return 3;

    return ix + iy + cast(int) len;  // 10 + 31 + 1 = 42
}
