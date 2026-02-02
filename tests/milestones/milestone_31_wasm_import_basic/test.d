extern(WASM, "test") int get_value();

int result() {
    return get_value();
}
