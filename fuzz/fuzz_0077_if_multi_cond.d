// EXPECTED: both
// EXPECTED: either
// EXPECTED: neither
int main() {
    int a = 5;
    int b = 10;
    if (a > 0 && b > 0) __writeln("both");
    if (a > 100 || b > 5) __writeln("either");
    if (a > 100 && b > 100) __writeln("neither");
    return 0;
}
