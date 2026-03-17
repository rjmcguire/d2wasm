// EXPECTED: 2147483647
// EXPECTED: -2147483648
int main() {
    int maxI = 2147483647;
    int minI = -2147483648;
    __writeln(maxI);
    __writeln(minI);
    return 0;
}
