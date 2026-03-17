// EXPECTED: 1
// EXPECTED: 7
// EXPECTED: 4
// EXPECTED: 16
int main() {
    int a = 3;
    a &= 1;
    __writeln(a);
    a |= 6;
    __writeln(a);
    a ^= 3;
    __writeln(a);
    a <<= 2;
    __writeln(a);
    return 0;
}
