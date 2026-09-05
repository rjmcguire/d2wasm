// extern(C) FFI to libc abs() — host native / WASM libffi
extern(C) int abs(int n);

int main() {
    return abs(-42);
}
