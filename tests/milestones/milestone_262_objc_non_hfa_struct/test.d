// Milestone 262: Non-HFA struct argument passing
//
// NSRange {long location, long length} is a 16-byte non-HFA struct.
// ARM64 ABI: passed in two GPRs (x2, x3) not float registers.
// Tests that the struct data (not its address) is passed correctly.

pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

struct NSRange { long location; long length; }

extern(Objective-C)
interface NSString {
    static NSString stringWithUTF8String(char* cstr);
    long length();
    // substringWithRange: takes NSRange (non-HFA, 16 bytes → x2+x3)
    NSString substringWithRange(NSRange range);
}

int main() {
    NSString s = NSString.stringWithUTF8String("hello world!".toStringz());

    // Extract "world" (location=6, length=5)
    NSRange r;
    r.location = 6;
    r.length = 5;
    NSString sub = s.substringWithRange(r);

    long subLen = sub.length();
    if (subLen != 5) return 1;

    // Extract "hello" (location=0, length=5)
    NSRange r2;
    r2.location = 0;
    r2.length = 5;
    NSString sub2 = s.substringWithRange(r2);

    long subLen2 = sub2.length();
    if (subLen2 != 5) return 2;

    // Extract full string (location=0, length=12)
    NSRange r3;
    r3.location = 0;
    r3.length = 12;
    NSString sub3 = s.substringWithRange(r3);

    long subLen3 = sub3.length();
    if (subLen3 != 12) return 3;

    return 42;
}
