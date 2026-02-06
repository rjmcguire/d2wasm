// milestone_119: Backend extraction refactor
// Verifies both WASM and native backends work after extraction to separate modules

int fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

int main() {
    return fib(10);  // 55
}
