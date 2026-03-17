// EXPECTED: 55
int fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

enum fib10 = fib(10);

int main() {
    __writeln(fib10);
    return 0;
}
