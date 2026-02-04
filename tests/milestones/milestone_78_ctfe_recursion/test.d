// Milestone 78: Recursive CTFE (self-recursion)

int fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

enum result = fib(10);

int main() {
    return result;  // fib(10) = 55
}
