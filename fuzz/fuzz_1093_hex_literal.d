// EXPECTED: 255
// EXPECTED: 4096
// EXPECTED: 48879
int main() {
    __writeln(0xFF);
    __writeln(0x1000);
    __writeln(0xBEEF);
    return 0;
}
