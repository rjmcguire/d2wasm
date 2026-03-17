// EXPECTED: 42
// EXPECTED: 0
// EXPECTED: 100
int main() {
    int x = 6 * 7;
    __writeln(x);
    __writeln(x % 7);
    __writeln((x / 6) * (x / 7) + (x / 42));
    return 0;
}
