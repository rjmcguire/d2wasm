// Milestone 263: objc_msgSendSuper for super calls
//
// D-defined ObjC class calls super.init() to properly chain initialization.
// Uses objc_msgSendSuper with objc_super { self, superclass } struct.

pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

extern(Objective-C)
interface NSObject {
    static NSObject alloc();
    NSObject init_() @selector("init");
}

int g_superCalled = 0;

extern(Objective-C)
class MyObj : NSObject {
    static MyObj myAlloc() @selector("alloc");
    MyObj myInit() @selector("init") {
        super.init_();
        g_superCalled = 1;
        return cast(MyObj) cast(long) this;
    }

    int getValue() @selector("getValue") {
        return 41 + g_superCalled;
    }
}

int main() {
    MyObj obj = MyObj.myAlloc().myInit();
    if (cast(long) obj == 0) return 1;
    return obj.getValue();  // 42 if super.init_() ran
}
