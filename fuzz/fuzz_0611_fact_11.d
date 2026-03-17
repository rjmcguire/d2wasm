// EXPECTED: 39916800
int factorial(int n) { if (n <= 1) return 1; return n * factorial(n - 1); }

int main() {
    __writeln(factorial(11));
    return 0;
}
