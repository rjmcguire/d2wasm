// EXPECTED: 1
// EXPECTED: 0
bool isPalin(int n) {
    int orig = n;
    int r = 0;
    while (n > 0) { r = r * 10 + n % 10; n /= 10; }
    return r == orig;
}

int main() {
    if (isPalin(121)) __writeln(1); else __writeln(0);
    if (isPalin(123)) __writeln(1); else __writeln(0);
    return 0;
}
