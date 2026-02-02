import __ctfe_runtime;

int compute() {
    int before = __ctfe_runtime.remaining();
    __ctfe_runtime.push();
    __ctfe_runtime.alloc(1000);
    __ctfe_runtime.pop();
    int after = __ctfe_runtime.remaining();
    // After pop, memory should be reclaimed
    return after >= before ? 1 : 0;
}

enum reclaimed = compute();

int result() {
    return reclaimed;
}
