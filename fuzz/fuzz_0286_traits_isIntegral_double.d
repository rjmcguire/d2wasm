// EXPECTED: 0
int main() {
    static if (__traits(isIntegral, double)) __writeln(1);
    else __writeln(0);
    return 0;
}
