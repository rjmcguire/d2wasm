// EXPECTED: 1
// EXPECTED: 0
int main() {
    static if (__traits(isArray, int[])) __writeln(1);
    else __writeln(0);
    static if (__traits(isArray, int)) __writeln(1);
    else __writeln(0);
    return 0;
}
