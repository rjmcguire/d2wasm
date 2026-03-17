// EXPECTED: 3
// EXPECTED: 0
// EXPECTED: -5
// EXPECTED: 2000000
int main() {
    int a = 1;
    int b = 2;
    __writeln(a + b);
    __writeln(0 + 0);
    __writeln(-10 + 5);
    __writeln(1000000 + 1000000);
    return 0;
}
