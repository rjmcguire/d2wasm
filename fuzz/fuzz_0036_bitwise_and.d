// EXPECTED: 0
// EXPECTED: 5
// EXPECTED: 1
// EXPECTED: 255
int main() {
    __writeln(0xFF & 0x00);
    __writeln(7 & 5);
    __writeln(3 & 1);
    __writeln(0xFF & 0xFF);
    return 0;
}
