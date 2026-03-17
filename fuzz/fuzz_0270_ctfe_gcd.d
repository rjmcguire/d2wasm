// EXPECTED: 6
int gcd(int a, int b) {
    if (b == 0) return a;
    return gcd(b, a % b);
}

enum g = gcd(12, 18);

int main() {
    __writeln(g);
    return 0;
}
