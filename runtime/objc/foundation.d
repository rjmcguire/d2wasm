// ObjC Foundation framework bindings
// Import with: import objc.foundation;

module objc.foundation;

pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

extern(Objective-C)
interface NSObject {
    static NSObject alloc();
    NSObject init_() @selector("init");
    void release();
    void retain();
    long hash();
}

extern(Objective-C)
interface NSString {
    static NSString alloc();
    static NSString stringWithUTF8String(char* cstr);
    NSString initWithUTF8String(char* cstr);
    long length();
    char* UTF8String();
}

extern(Objective-C)
interface NSMutableString {
    static NSMutableString alloc();
    NSMutableString initWithUTF8String(char* cstr);
    void appendString(NSString str);
    long length();
}

extern(Objective-C)
interface NSNumber {
    static NSNumber numberWithInt(int value);
    static NSNumber numberWithDouble(double value);
    int intValue();
    double doubleValue();
    long longValue();
}

extern(Objective-C)
interface NSArray {
    static NSArray alloc();
    long count();
    NSObject objectAtIndex(long index);
}

extern(Objective-C)
interface NSMutableArray {
    static NSMutableArray alloc();
    NSMutableArray init_() @selector("init");
    void addObject(NSObject obj);
    long count();
    NSObject objectAtIndex(long index);
}

extern(Objective-C)
interface NSDictionary {
    static NSDictionary alloc();
    long count();
}

extern(Objective-C)
interface NSDate {
    static NSDate dateWithTimeIntervalSinceNow(double secs);
}

extern(Objective-C)
interface NSValue {
    static NSValue alloc();
}

// ObjC runtime helpers
extern(C) long objc_autoreleasePoolPush();
extern(C) void objc_autoreleasePoolPop(long pool);
