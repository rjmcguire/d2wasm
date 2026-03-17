// EXPECTED: 171
// EXPECTED: 10
// EXPECTED: 11
int main() {
    int val = 0xABCD;
    __writeln((val >> 8) & 0xFF);
    int low = val & 0xF;
    __writeln(low);
    int nibble2 = (val >> 4) & 0xF;
    __writeln(nibble2);
    return 0;
}
