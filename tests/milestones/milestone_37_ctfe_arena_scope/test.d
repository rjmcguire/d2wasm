import __ctfe_runtime;

int compute() {
    // Push a new arena scope
    __ctfe_runtime.push();
    
    // Allocate in the nested scope (this memory will be reclaimed)
    __ctfe_runtime.alloc(1000);
    
    // Pop - reclaims the 1000 bytes
    __ctfe_runtime.pop();
    
    // Now allocate again - should get pointer at 1024 (MEMORY_RESERVED)
    // since the nested allocation was reclaimed
    int ptr = __ctfe_runtime.alloc(100);
    return ptr;
}

enum reclaimed = compute();

int result() {
    return reclaimed;
}
