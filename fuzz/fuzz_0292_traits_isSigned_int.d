// EXPECTED: 1
int main() {
    static if (__traits(isSigned, int)) __writeln(1);
    else __writeln(0);
    return 0;
}
