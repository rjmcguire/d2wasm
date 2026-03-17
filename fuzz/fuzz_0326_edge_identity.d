// EXPECTED: 42
// EXPECTED: 42
// EXPECTED: 42
int main() {
    int x = 42;
    __writeln(x + 0);
    __writeln(x * 1);
    __writeln(x - 0);
    return 0;
}
