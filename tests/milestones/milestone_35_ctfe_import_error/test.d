extern(WASM, "test") int get_value();

enum x = get_value();  // Error: runtime import not available at CTFE

int result() {
    return x;
}
