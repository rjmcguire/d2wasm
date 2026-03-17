// EXPECTED: 3000000000
// EXPECTED: -1
int main() {
    long a = 1000000000;
    long b = 2000000000;
    __writeln(a + b);
    long c = -1;
    __writeln(c);
    return 0;
}
