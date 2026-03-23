// STATUS: maybeLater — static if not parsed in function bodies
// EXPECTED: 1
int main() {
    static if (__traits(isArithmetic, double)) __writeln(1);
    else __writeln(0);
    return 0;
}
