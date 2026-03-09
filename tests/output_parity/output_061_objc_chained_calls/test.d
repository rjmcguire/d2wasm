// ObjC chained expression receivers: alloc().init_().count()
pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

extern(Objective-C)
interface NSMutableArray {
    static NSMutableArray alloc() @selector("alloc");
    NSMutableArray init_() @selector("init");
    long count() @selector("count");
}

int main() {
    long c = NSMutableArray.alloc().init_().count();
    if (c == 0) return 42;
    return 1;
}
