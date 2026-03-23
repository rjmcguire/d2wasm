// STATUS: maybeLater — literal narrowing not implemented
// EXPECTED: 1000
int main() {
    ushort a = 500;
    ushort b = 500;
    __writeln(a + b);
    return 0;
}
