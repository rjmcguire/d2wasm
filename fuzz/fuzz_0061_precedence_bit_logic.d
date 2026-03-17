// EXPECTED: 1
// EXPECTED: 3
// EXPECTED: 7
int main() {
    __writeln(3 & 1 | 0);
    __writeln(1 | 2 & 3);
    __writeln(5 | 2 ^ 0);
    return 0;
}
