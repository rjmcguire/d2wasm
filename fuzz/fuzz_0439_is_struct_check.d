// STATUS: maybeLater — static if not parsed in function bodies
// EXPECTED: 1
struct S { int x; }

int main() {
    static if (is(S == struct)) __writeln(1);
    else __writeln(0);
    return 0;
}
