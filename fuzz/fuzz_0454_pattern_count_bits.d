// EXPECTED: 3
int countBits(int n) {
    int c = 0;
    while (n > 0) { c += n & 1; n >>= 1; }
    return c;
}

int main() {
    __writeln(countBits(7));
    return 0;
}
