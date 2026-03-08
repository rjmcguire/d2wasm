// Milestone 226: extern(Objective-C) class definitions
//
// Defines an ObjC class in D with method implementations. The compiler:
//   1. Parses the class with extern(Objective-C) linkage
//   2. Compiles method bodies as exported WASM functions
//   3. Emits an objc_classes custom section with class metadata
//   4. Runtime registers the class via objc_allocateClassPair + class_addMethod
//
// The test defines a simple NSObject subclass with a method that returns 42.
// We instantiate it via NSObject's alloc/init, then use the class type for dispatch.

extern(Objective-C)
interface NSObject {
    static NSObject alloc() @selector("alloc");
    NSObject init_() @selector("init");
}

extern(Objective-C)
class MyHelper : NSObject {
    // alloc/init return self-typed i64 — we re-declare them for our class
    static MyHelper myAlloc() @selector("alloc");
    MyHelper myInit() @selector("init");

    int getValue() @selector("getValue") {
        return 42;
    }
}

int main() {
    // Instantiate using our class's re-declared alloc/init
    MyHelper obj = MyHelper.myAlloc().myInit();

    // Call our method — ObjC runtime dispatches to our WASM implementation
    int val = obj.getValue();

    return val;
}
