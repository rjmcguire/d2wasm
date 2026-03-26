// Milestone 264: Typed ObjC references (id, Class, SEL)
//
// Uses the id/Class/SEL type aliases from runtime/object.d instead of
// raw long for untyped ObjC pointers. Physically identical to long.

pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

extern(Objective-C)
interface NSString {
    static NSString stringWithUTF8String(char* cstr);
    long length();
}

// Use 'id' instead of 'long' for untyped ObjC object pointers
extern(C) id objc_getClass(char* name);

int main() {
    // id as a variable type for untyped ObjC pointers
    id cls = objc_getClass("NSString".toStringz());
    if (cls == 0) return 1;

    // Regular typed ObjC call
    NSString s = NSString.stringWithUTF8String("hello".toStringz());
    long len = s.length();
    if (len != 5) return 2;

    // id as a cast target (same as casting to long)
    id ptr = cast(id) s;
    if (ptr == 0) return 3;

    return 42;
}
