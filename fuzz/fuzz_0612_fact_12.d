// EXPECTED: 479001600
int factorial(int n) { if (n <= 1) return 1; return n * factorial(n - 1); }

int main() {
    __writeln(factorial(12));
    return 0;
}
