// EXPECTED: 1
int main() {
    static if (__traits(isUnsigned, ulong)) __writeln(1);
    else __writeln(0);
    return 0;
}
