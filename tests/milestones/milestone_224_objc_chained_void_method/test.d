// Milestone 224: expressionHasValue for void methods on chained ObjC calls
//
// When a void method (e.g., removeAllObjects) is called on an expression
// receiver (not a named variable), expressionHasValue must correctly
// identify it as void. Without the fix, the emitter assumes unknown calls
// return a value and emits a spurious `drop` → stack underflow/corruption.
//
// This test chains: alloc().init_().removeAllObjects() where the final
// call is void. If expressionHasValue is wrong, compilation or execution
// will fail with a stack error.

extern(Objective-C)
interface NSMutableArray {
    static NSMutableArray alloc() @selector("alloc");
    NSMutableArray init_() @selector("init");
    void removeAllObjects() @selector("removeAllObjects");
    long count() @selector("count");
}

int main() {
    // Void method on expression receiver — must NOT emit drop
    NSMutableArray.alloc().init_().removeAllObjects();

    // Verify a named-var path still works too
    NSMutableArray arr = NSMutableArray.alloc().init_();
    arr.removeAllObjects();

    if (arr.count() == 0) return 42;
    return 1;
}
