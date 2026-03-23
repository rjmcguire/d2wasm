// STATUS: maybeLater — literal narrowing not implemented
// EXPECTED: 127
// EXPECTED: -128
int main() {
    byte maxB = 127;
    byte minB = -128;
    __writeln(maxB);
    __writeln(minB);
    return 0;
}
