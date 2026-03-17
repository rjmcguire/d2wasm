// EXPECTED: 55
int sumTo(int n) {
    if (n == 0) return 0;
    return n + sumTo(n - 1);
}

enum s = sumTo(10);

int main() {
    __writeln(s);
    return 0;
}
