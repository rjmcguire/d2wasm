// EXPECTED: 6
// EXPECTED: 0
// EXPECTED: 255
// EXPECTED: 15
int main() {
    __writeln(5 ^ 3);
    __writeln(7 ^ 7);
    __writeln(0xFF ^ 0x00);
    __writeln(0x0F ^ 0x00);
    return 0;
}
