// EXPECTED: 1
int main() {
    static if (__traits(isStaticArray, int[3])) __writeln(1);
    else __writeln(0);
    return 0;
}
