// EXPECTED: 15
int sum(int n) { return n == 0 ? 0 : n + sum(n - 1); }

int main() {
    __writeln(sum(5));
    return 0;
}
