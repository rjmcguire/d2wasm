// EXPECTED: 1024
// EXPECTED: 1
// EXPECTED: 8
int power(int base, int exp) {
    if (exp == 0) return 1;
    return base * power(base, exp - 1);
}

int main() {
    __writeln(power(2, 10));
    __writeln(power(5, 0));
    __writeln(power(2, 3));
    return 0;
}
