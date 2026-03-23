// STATUS: maybeLater — literal narrowing not implemented
// EXPECTED: 4294967295
// EXPECTED: 0
int main() {
    uint maxUI = 4294967295;
    uint minUI = 0;
    __writeln(maxUI);
    __writeln(minUI);
    return 0;
}
