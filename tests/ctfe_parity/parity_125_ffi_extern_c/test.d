// Parity 125: extern(C) FFI — call objc_getClass via native FFI
// Verifies: extern(C) declaration, ImportedFunctionDecl, i64 return,
//           string null termination, pointer passing to C

extern(C) long objc_getClass(const(char)* name);

int main() {
    long cls = objc_getClass("NSObject\0".ptr);
    if (cls != 0) return 42;
    return 1;
}
