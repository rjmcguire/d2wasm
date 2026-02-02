import __ctfe_runtime;

int compute() {
    auto ptr = __ctfe_runtime.alloc(100);
    return ptr > 0 ? 1 : 0;
}

enum allocated = compute();

int result() {
    return allocated;
}
