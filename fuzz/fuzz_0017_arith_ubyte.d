// STATUS: maybeLater — literal narrowing not implemented
// EXPECTED: 255
// EXPECTED: 0
// EXPECTED: 200
int main() {
    ubyte a = 255;
    __writeln(a);
    ubyte b = 0;
    __writeln(b);
    __writeln(a - 55);
    return 0;
}
