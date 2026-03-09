// ObjC class defined in D with method body, registered at runtime
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

    int getValue() @selector("getValue") {
        return 42;
    }
}

int main() {
    MyHelper obj = MyHelper.myAlloc().myInit();
    int val = obj.getValue();
    return val;
}
