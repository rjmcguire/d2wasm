// STATUS: maybeLater — do-while not parsed
// EXPECTED: 5
int main() {
    int c = 0;
    do { c++; } while (c < 5);
    __writeln(c);
    return 0;
}
