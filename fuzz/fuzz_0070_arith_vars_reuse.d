// EXPECTED: 10
// EXPECTED: 20
// EXPECTED: 15
// EXPECTED: 5
int main() {
    int a = 10;
    __writeln(a);
    a = a * 2;
    __writeln(a);
    a = a - 5;
    __writeln(a);
    a = a / 3;
    __writeln(a);
    return 0;
}
