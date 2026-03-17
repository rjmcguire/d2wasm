// EXPECTED: 55
int sum_to(int n) {
    if (n == 0) return 0;
    return n + sum_to(n - 1);
}

int main() {
    __writeln(sum_to(10));
    return 0;
}
