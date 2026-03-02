extern(C) long objc_getClass(const(char)* name);

int main() {
    long cls = objc_getClass("NSObject\0".ptr);
    //return cls != 0 ? 42 : 1;
    if (cls != 0) return 42;
    return 1;
}
