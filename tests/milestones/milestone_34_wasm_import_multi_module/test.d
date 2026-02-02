extern(WASM, "math") int add(int a, int b);
extern(WASM, "constants") int get_forty();
extern(WASM, "constants") int get_two();

int result() {
    return add(get_forty(), get_two());
}
