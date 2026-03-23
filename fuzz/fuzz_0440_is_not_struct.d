// STATUS: maybeLater — static if not parsed in function bodies
// EXPECTED: 0
int main() {
    static if (is(int == struct)) __writeln(1);
    else __writeln(0);
    return 0;
}
