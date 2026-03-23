// STATUS: maybeLater — literal narrowing not implemented
// EXPECTED: 30000
// EXPECTED: -30000
// EXPECTED: 0
int main() {
    short a = 10000;
    short b = 20000;
    __writeln(a + b);
    __writeln(-a - b);
    __writeln(a - a);
    return 0;
}
