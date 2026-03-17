// EXPECTED: 1
// EXPECTED: 1
int main() {
    // byte is implicitly convertible to int
    static if (is(byte : int)) __writeln(1);
    else __writeln(0);
    static if (is(int : long)) __writeln(1);
    else __writeln(0);
    return 0;
}
