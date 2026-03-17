// EXPECTED: 0
// EXPECTED: 0
// EXPECTED: 0
int main() {
    __writeln(0 * 1000000);
    __writeln(999 * 0);
    __writeln(-1 * 0);
    return 0;
}
