// EXPECTED: 6
// EXPECTED: 1
// EXPECTED: 12
int gcd(int a, int b) {
    if (b == 0) return a;
    return gcd(b, a % b);
}

int main() {
    __writeln(gcd(12, 18));
    __writeln(gcd(7, 13));
    __writeln(gcd(24, 36));
    return 0;
}
