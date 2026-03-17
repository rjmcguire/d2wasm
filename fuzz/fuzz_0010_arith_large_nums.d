// EXPECTED: 2000000000
// EXPECTED: 1000000
// EXPECTED: -2000000000
int main() {
    int a = 1000000000;
    int b = 1000000000;
    __writeln(a + b);
    __writeln(a / 1000);
    __writeln(-a - b);
    return 0;
}
