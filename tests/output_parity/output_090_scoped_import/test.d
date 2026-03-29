// Output parity: scoped imports inside function bodies
// Tests selective, wildcard, and block-scoped import visibility
// across wasm, native, and native-jit backends.

int useSelectiveScoped() {
    import helper : add;
    return add(10, 20);  // 30
}

int useWildcardScoped() {
    import helper;
    return mul(3, 4);  // 12
}

int main() {
    return useSelectiveScoped() + useWildcardScoped();  // 42
}
