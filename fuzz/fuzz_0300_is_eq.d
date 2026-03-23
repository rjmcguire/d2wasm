// STATUS: maybeLater — static if not parsed in function bodies
// EXPECTED: 1
// EXPECTED: 0
int main() {
    static if (is(int == int)) __writeln(1);
    else __writeln(0);
    static if (is(int == long)) __writeln(1);
    else __writeln(0);
    return 0;
}
