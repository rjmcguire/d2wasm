// EXPECTED: 10
// EXPECTED: 3000000000
// EXPECTED: 0
int main() {
    uint a = 7;
    uint b = 3;
    __writeln(a + b);
    uint c = 3000000000;
    __writeln(c);
    __writeln(a - a);
    return 0;
}
