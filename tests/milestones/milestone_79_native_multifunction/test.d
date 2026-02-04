// Milestone 79: Multi-function native backend
// Tests D-to-D calls with native CTFE

int fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

// Force CTFE with native backend
enum result = fib(10);

int main() {
    return result;  // fib(10) = 55
}
