// Milestone 227: ObjC class calling inherited interface methods
//
// An extern(Objective-C) class inheriting from an interface should be able
// to call methods declared on the parent interface. Previously the type
// checker only searched the class's own members, not inherited ones.

extern(Objective-C)
interface NSObject {
    static NSObject alloc() @selector("alloc");
    NSObject init_() @selector("init");
    long hash_() @selector("hash");
}

extern(Objective-C)
class MyObj : NSObject {
    static MyObj myAlloc() @selector("alloc");
    MyObj myInit() @selector("init");

    int getValue() @selector("getValue") {
        return 10;
    }
}

int main() {
    MyObj obj = MyObj.myAlloc().myInit();

    // Call own method
    int val = obj.getValue();
    if (val != 10) return 1;

    // Call inherited method from NSObject interface
    long h = obj.hash_();
    if (h == 0) return 2;  // hash of a valid object should be non-zero

    return 42;
}
