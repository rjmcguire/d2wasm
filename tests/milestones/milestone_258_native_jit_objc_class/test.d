// Milestone 258: Native JIT ObjC class registration
//
// Tests that extern(Objective-C) classes defined in D are properly registered
// with the ObjC runtime in native ARM64 JIT mode. Covers:
//   1. Class registration via objc_allocateClassPair + class_addMethod
//   2. Register-shift trampoline for methods with user parameters
//   3. Zero-param methods (no trampoline needed)
//   4. Calling D-body methods via ObjC dispatch

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

    // 1-param method: trampoline shifts x2→x1 (skipping _cmd)
    int addValue(int x) @selector("addValue:") {
        return x;
    }
}

int main() {
    MyHelper obj = MyHelper.myAlloc().myInit();

    int base = obj.getBase();     // 0-param: direct IMP, expect 40
    int added = obj.addValue(2);  // 1-param: trampoline, expect 2

    return base + added;          // 40 + 2 = 42
}
