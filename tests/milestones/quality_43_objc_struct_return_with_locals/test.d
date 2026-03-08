// Bug: ObjC struct return breaks when caller has 2+ struct locals.
//
// 1 struct local + struct return → PASS
// 2 struct locals + struct return → FAIL (exit 4: result.x != 3.0)
//
// The struct return from pointValue() produces wrong data when the
// calling function has enough struct locals to push the frame past
// a certain size.
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

int main() {
    // Two struct locals — triggers the bug
    MyRect a;
    a.x = 1.0; a.y = 2.0; a.w = 3.0; a.h = 4.0;

    MyRect b;
    b.x = 5.0; b.y = 6.0; b.w = 7.0; b.h = 8.0;

    if (a.x != 1.0) return 1;
    if (b.x != 5.0) return 2;

    MyPoint p;
    p.x = 3.0;
    p.y = 7.0;
    NSValue val = NSValue.valueWithPoint(p);
    if (cast(long)val == 0) return 3;

    MyPoint result = val.pointValue();
    if (result.x != 3.0) return 4;
    if (result.y != 7.0) return 5;

    return 42;
}
