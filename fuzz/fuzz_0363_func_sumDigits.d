// EXPECTED: 6
// EXPECTED: 15
int sumDigits(int n) {
    int s = 0;
    while (n > 0) { s += n % 10; n /= 10; }
    return s;
}

int main() {
    __writeln(sumDigits(123));
    __writeln(sumDigits(555));
    return 0;
}
