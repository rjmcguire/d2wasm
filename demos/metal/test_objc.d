// Minimal test: extern(Objective-C) static method call
// Tests: parse -> type check -> emit -> link -> call objc_msgSend
// Returns 42 on success, 1 on failure

extern(Objective-C)
interface NSObject {
    static long alloc() @selector("alloc");
}

int main() {
    long obj = NSObject.alloc();
    if (obj != 0) {
        return 42;
    }
    return 1;
}
