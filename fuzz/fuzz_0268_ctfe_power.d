// EXPECTED: 1024
int power(int base, int exp) {
    if (exp == 0) return 1;
    return base * power(base, exp - 1);
}

enum p = power(2, 10);

int main() {
    __writeln(p);
    return 0;
}
