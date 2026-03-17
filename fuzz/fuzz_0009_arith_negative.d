// EXPECTED: -5
// EXPECTED: 5
// EXPECTED: -1
// EXPECTED: 1
int main() {
    int a = -5;
    __writeln(a);
    __writeln(-a);
    __writeln(-1);
    __writeln(-(-1));
    return 0;
}
