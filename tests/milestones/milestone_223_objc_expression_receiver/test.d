// Milestone 223: ObjC method calls on expression receivers
//
// emitMethodCall previously required method receivers to be named
// variables (IdentifierExpression). Now any expression with a resolved
// ObjC interface type can be a receiver, enabling chaining like:
//   NSMutableArray.alloc().init_().count()
//
// This test chains 3 ObjC calls: alloc() is static, init_() is called
// on the expression result of alloc(), and count() is called on the
// expression result of init_(). The last two exercise expression receivers.

extern(Objective-C)
interface NSMutableArray {
    static NSMutableArray alloc() @selector("alloc");
    NSMutableArray init_() @selector("init");
    long count() @selector("count");
}

int main() {
    // Chain: alloc() returns expression, init_() called on that expression,
    // count() called on that expression — all via expression receiver dispatch
    long c = NSMutableArray.alloc().init_().count();

    // A freshly-init'd array has count 0
    if (c == 0) return 42;
    return 1;
}
