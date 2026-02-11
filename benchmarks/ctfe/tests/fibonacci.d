// CTFE Benchmark: Recursive Fibonacci
// Tests: function call overhead, recursion depth

int fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

enum RESULT = fib(20);

int main() {
    return RESULT;
}
