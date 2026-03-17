// EXPECTED: 2
// EXPECTED: 8
// EXPECTED: 256
// EXPECTED: 1024
int main() {
    __writeln(1 << 1);
    __writeln(1 << 3);
    __writeln(1 << 8);
    __writeln(1 << 10);
    return 0;
}
