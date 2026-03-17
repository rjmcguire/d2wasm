// EXPECTED: 0
int main() {
    static if (__traits(isArithmetic, bool)) __writeln(1);
    else __writeln(0);
    return 0;
}
