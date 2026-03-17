// EXPECTED: 3
int numDigits(int n) {
    int c = 0;
    while (n > 0) { n /= 10; c++; }
    return c;
}

int main() {
    __writeln(numDigits(123));
    return 0;
}
