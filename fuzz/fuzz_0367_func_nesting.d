// STATUS: maybeLater — nested functions not parsed
// EXPECTED: 42
int main() {
    int a(int x) { return x + 2; }
    int b(int x) { return a(x) * 2; }
    __writeln(b(19));
    return 0;
}
