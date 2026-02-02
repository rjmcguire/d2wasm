extern(WASM, "test") int add(int a, int b);

int result() {
    return add(17, 25);
}
