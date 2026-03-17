// EXPECTED: 5040
int factorial(int n) { if (n <= 1) return 1; return n * factorial(n - 1); }

int main() {
    __writeln(factorial(7));
    return 0;
}
