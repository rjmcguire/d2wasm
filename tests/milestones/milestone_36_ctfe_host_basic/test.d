import __ctfe_runtime;

int compute() {
    // Allocate 100 bytes, should return pointer starting at MEMORY_RESERVED (2048)
    int ptr = __ctfe_runtime.alloc(100);
    return ptr;
}

enum allocated = compute();

int result() {
    return allocated;
}
