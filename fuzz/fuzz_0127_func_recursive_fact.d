// EXPECTED: 120
// EXPECTED: 1
// EXPECTED: 6
int factorial(int n) {
    if (n <= 1) return 1;
    return n * factorial(n - 1);
}

int main() {
    __writeln(factorial(5));
    __writeln(factorial(0));
    __writeln(factorial(3));
    return 0;
}
