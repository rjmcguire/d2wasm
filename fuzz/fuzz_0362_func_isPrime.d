// EXPECTED: 1
// EXPECTED: 0
// EXPECTED: 1
bool isPrime(int n) {
    if (n < 2) return false;
    for (int i = 2; i * i <= n; i++) {
        if (n % i == 0) return false;
    }
    return true;
}

int main() {
    if (isPrime(7)) __writeln(1); else __writeln(0);
    if (isPrime(9)) __writeln(1); else __writeln(0);
    if (isPrime(13)) __writeln(1); else __writeln(0);
    return 0;
}
