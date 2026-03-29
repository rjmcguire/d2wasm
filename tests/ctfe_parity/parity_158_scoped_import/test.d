// CTFE Parity Test: Scoped imports inside function bodies
// Both wasm and native backends should handle import declarations
// inside function bodies, restricting visibility to the enclosing scope.

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
