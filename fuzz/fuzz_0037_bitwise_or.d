// EXPECTED: 255
// EXPECTED: 7
// EXPECTED: 3
// EXPECTED: 15
int main() {
    __writeln(0xFF | 0x00);
    __writeln(5 | 3);
    __writeln(1 | 2);
    __writeln(0x0F | 0x00);
    return 0;
}
