// EXPECTED: 0
int main() {
    static if (__traits(isFloating, long)) __writeln(1);
    else __writeln(0);
    return 0;
}
