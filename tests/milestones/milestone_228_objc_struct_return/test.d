// Milestone 228: ObjC method returning struct
//
// Tests that extern(Objective-C) interface methods returning structs work.
// Uses NSValue to box and unbox an NSPoint (two doubles), exercising the
// hidden result pointer calling convention through the FFI trampoline.

pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

struct NSPoint { double x; double y; }
struct NSRange { long location; long length; }

extern(Objective-C)
interface NSObject {
    static NSObject alloc() @selector("alloc");
    NSObject init_() @selector("init");
}

extern(Objective-C)
interface NSValue {
    static NSValue valueWithPoint(NSPoint point) @selector("valueWithPoint:");
    NSPoint pointValue() @selector("pointValue");
    static NSValue valueWithRange(NSRange range) @selector("valueWithRange:");
    NSRange rangeValue() @selector("rangeValue");
}

int main() {
    // Box an NSPoint into NSValue, then unbox it
    NSPoint p;
    p.x = 3.0;
    p.y = 7.0;

    NSValue val = NSValue.valueWithPoint(p);
    if (cast(long)val == 0) return 1;

    // Struct return: pointValue returns NSPoint via hidden result pointer
    NSPoint result = val.pointValue();

    // Verify round-trip
    if (result.x != 3.0) return 2;
    if (result.y != 7.0) return 3;

    // Test NSRange (two longs) — different field types
    NSRange r;
    r.location = 10;
    r.length = 20;

    NSValue val2 = NSValue.valueWithRange(r);
    if (cast(long)val2 == 0) return 4;

    NSRange result2 = val2.rangeValue();
    if (result2.location != 10) return 5;
    if (result2.length != 20) return 6;

    return 42;
}
