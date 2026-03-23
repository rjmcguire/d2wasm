// STATUS: maybeLater — literal narrowing not implemented
// EXPECTED: 1000
int main() {
    short a = 1000;
    long b = cast(long)a;
    __writeln(b);
    return 0;
}
