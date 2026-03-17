// EXPECTED: 4
bool isPrime(int n) {
    if (n < 2) return false;
    for (int i = 2; i * i <= n; i++) if (n % i == 0) return false;
    return true;
}

int main() {
    int c = 0;
    for (int i = 2; i <= 10; i++) if (isPrime(i)) c++;
    __writeln(c);
    return 0;
}
