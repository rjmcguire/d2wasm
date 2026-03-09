// Basic ObjC: alloc/init an NSObject, verify non-null
pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

extern(Objective-C)
interface NSObject {
    static NSObject alloc() @selector("alloc");
    NSObject init_() @selector("init");
}

int main() {
    NSObject obj = NSObject.alloc().init_();
    if (cast(long)obj != 0) return 42;
    return 1;
}
