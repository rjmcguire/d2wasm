// EXPECTED: 55
// EXPECTED: 1
// EXPECTED: 8
int fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

int main() {
    __writeln(fib(10));
    __writeln(fib(1));
    __writeln(fib(6));
    return 0;
}
