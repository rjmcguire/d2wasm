// Test: extern(Objective-C) static + instance method calls
// Tests: parse -> type check -> emit -> link -> objc_msgSend dispatch
// Returns 42 on success, 1 on failure

extern(Objective-C)
interface NSObject {
    static NSObject alloc() @selector("alloc");
    NSObject init_() @selector("init");
    void release() @selector("release");
}

int main() {
    NSObject obj = NSObject.alloc();
    obj = obj.init_();
    obj.release();
    return 42;
}
