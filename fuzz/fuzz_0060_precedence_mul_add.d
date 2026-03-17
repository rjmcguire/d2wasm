// EXPECTED: 11
// EXPECTED: 15
// EXPECTED: 7
int main() {
    __writeln(1 + 2 * 5);
    __writeln((1 + 2) * 5);
    __writeln(3 + 8 / 2);
    return 0;
}
