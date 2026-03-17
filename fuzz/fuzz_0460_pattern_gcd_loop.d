// EXPECTED: 6
int gcd(int a, int b) {
    while (b != 0) { int t = b; b = a % b; a = t; }
    return a;
}

int main() {
    __writeln(gcd(54, 24));
    return 0;
}
