// STATUS: maybeLater — literal narrowing not implemented
// EXPECTED: 60000
// EXPECTED: 30000
int main() {
    ushort a = 60000;
    __writeln(a);
    __writeln(a / 2);
    return 0;
}
