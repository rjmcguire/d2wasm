// Test struct return with NO struct params - isolate the exact bug
pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

struct MyPoint { double x; double y; }
struct MyRect { double x; double y; double w; double h; }

extern(Objective-C)
interface NSObject {
    static NSObject alloc() @selector("alloc");
    NSObject init_() @selector("init");
}

extern(Objective-C)
interface NSValue {
    static NSValue valueWithPoint(MyPoint point) @selector("valueWithPoint:");
    MyPoint pointValue() @selector("pointValue");
}

// Separate function to create the NSValue (isolates struct param from main's frame)
long createValue() {
    MyPoint p;
    p.x = 3.0;
    p.y = 7.0;
    NSValue val = NSValue.valueWithPoint(p);
    return cast(long)val;
}

int main() {
    MyRect a;
    a.x = 1.0; a.y = 2.0; a.w = 3.0; a.h = 4.0;

    MyRect b;
    b.x = 5.0; b.y = 6.0; b.w = 7.0; b.h = 8.0;

    if (a.x != 1.0) return 1;
    if (b.x != 5.0) return 2;

    // Create NSValue in separate function (no struct param in main's frame)
    long valPtr = createValue();
    if (valPtr == 0) return 3;

    NSValue val = cast(NSValue) valPtr;
    MyPoint result = val.pointValue();
    if (result.x != 3.0) return 4;
    if (result.y != 7.0) return 5;

    return 42;
}
