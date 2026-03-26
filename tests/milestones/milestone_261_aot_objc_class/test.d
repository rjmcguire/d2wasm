// Milestone 261: AOT ObjC class registration via constructor
//
// Tests that D-defined extern(Objective-C) classes are registered with the
// ObjC runtime in AOT-compiled binaries. The __objc_class_init constructor
// runs before main() and calls objc_allocateClassPair + class_addMethod +
// objc_registerClassPair.

pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

extern(Objective-C)
interface NSObject {
    static NSObject alloc() @selector("alloc");
    NSObject init_() @selector("init");
}

extern(Objective-C)
class MyHelper : NSObject {
    static MyHelper myAlloc() @selector("alloc");
    MyHelper myInit() @selector("init");

    // 0-param method: no trampoline needed
    int getBase() @selector("getBase") {
        return 40;
    }

    // 1-param method: trampoline shifts x2→x1
    int addValue(int x) @selector("addValue:") {
        return x;
    }
}

int main() {
    MyHelper obj = MyHelper.myAlloc().myInit();

    int base = obj.getBase();
    int added = obj.addValue(2);

    if (base != 40) return 1;
    if (added != 2) return 2;

    return base + added;  // 42
}
