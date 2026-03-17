// EXPECTED: 6
int factorial(int n) { if (n <= 1) return 1; return n * factorial(n - 1); }

int main() {
    __writeln(factorial(3));
    return 0;
}
