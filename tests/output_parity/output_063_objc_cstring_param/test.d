// Pass D string to ObjC via toStringz(), verify NSString length
pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

extern(Objective-C)
interface NSString {
    static NSString stringWithUTF8String(char* cstr) @selector("stringWithUTF8String:");
    long length() @selector("length");
}

int main() {
    NSString hello = NSString.stringWithUTF8String("hello".toStringz());
    if (cast(long)hello == 0) return 1;
    if (hello.length() != 5) return 2;

    NSString empty = NSString.stringWithUTF8String("".toStringz());
    if (cast(long)empty == 0) return 3;
    if (empty.length() != 0) return 4;

    return 42;
}
