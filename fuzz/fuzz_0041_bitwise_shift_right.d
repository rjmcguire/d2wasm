// EXPECTED: 4
// EXPECTED: 1
// EXPECTED: 0
// EXPECTED: 64
int main() {
    __writeln(8 >> 1);
    __writeln(8 >> 3);
    __writeln(1 >> 1);
    __writeln(256 >> 2);
    return 0;
}
