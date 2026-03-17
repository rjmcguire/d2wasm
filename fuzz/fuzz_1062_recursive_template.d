// EXPECTED: 120
int factorial(int N)() if (N <= 1) {
    return 1;
}

int factorial(int N)() if (N > 1) {
    return N * factorial!(N - 1)();
}

int main() {
    __writeln(factorial!5());
    return 0;
}
