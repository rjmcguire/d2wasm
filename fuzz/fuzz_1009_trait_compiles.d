// STATUS: maybeLater — static if not parsed in function bodies
// EXPECTED: 1
// EXPECTED: 0
int main() {
    static if (__traits(compiles, 1 + 2)) __writeln(1);
    else __writeln(0);
    static if (__traits(compiles, "hello" + 1)) __writeln(1);
    else __writeln(0);
    return 0;
}
