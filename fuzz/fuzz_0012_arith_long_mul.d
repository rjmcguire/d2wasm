// STATUS: bug — wrong output
// EXPECTED: 1000000000000
// EXPECTED: -1000000000000
int main() {
    long a = 1000000;
    long b = 1000000;
    __writeln(a * b);
    __writeln(-a * b);
    return 0;
}
