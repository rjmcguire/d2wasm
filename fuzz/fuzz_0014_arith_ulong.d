// STATUS: bug — compile error
// EXPECTED: 10000000000
// EXPECTED: 5000000000
int main() {
    ulong a = 10000000000;
    __writeln(a);
    __writeln(a / 2);
    return 0;
}
