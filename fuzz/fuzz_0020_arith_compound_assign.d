// EXPECTED: 15
// EXPECTED: 12
// EXPECTED: 36
// EXPECTED: 9
// EXPECTED: 0
int main() {
    int a = 10;
    a += 5;
    __writeln(a);
    a -= 3;
    __writeln(a);
    a *= 3;
    __writeln(a);
    a /= 4;
    __writeln(a);
    a %= 3;
    __writeln(a);
    return 0;
}
