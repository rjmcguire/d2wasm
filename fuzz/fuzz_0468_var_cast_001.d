// STATUS: maybeLater — literal narrowing not implemented
// EXPECTED: 200
int main() {
    ubyte a = 200;
    int b = cast(int)a;
    __writeln(b);
    return 0;
}
