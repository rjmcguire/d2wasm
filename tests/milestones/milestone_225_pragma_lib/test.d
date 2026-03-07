pragma(lib, "/System/Library/Frameworks/Foundation.framework/Foundation");

extern(C) long objc_getClass(const(char)* name);

int main() {
    long cls = objc_getClass("NSObject\0".ptr);
    if (cls != 0) return 42;
    return 1;
}
