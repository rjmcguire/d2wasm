// EXPECTED: 24
int mul(int a, int b) {
    if (b == 0) return 0;
    return a + mul(a, b - 1);
}

int main() {
    __writeln(mul(6, 4));
    return 0;
}
