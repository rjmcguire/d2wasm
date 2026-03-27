// EXPECTED: 30
// EXPECTED: 100
// EXPECTED: -50
int main() {
    byte a = 10;
    byte b = 20;
    __writeln(a + b);
    __writeln(a * b / 2);
    byte c = -50;
    __writeln(c);
    return 0;
}
