extern(WASM, "test") void set_value(int x);
extern(WASM, "test") int get_value();

int result() {
    set_value(42);
    return get_value();
}
