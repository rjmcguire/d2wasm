// STATUS: maybeLater — ternary not parsed
// EXPECTED: 10
int absVal(int x) => x >= 0 ? x : -x;

int main() {
    __writeln(absVal(-10));
    return 0;
}
