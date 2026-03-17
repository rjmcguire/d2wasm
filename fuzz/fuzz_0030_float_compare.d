// EXPECTED: 1
// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 1
int main() {
    double a = 3.14;
    double b = 2.71;
    if (a > b) __writeln(1); else __writeln(0);
    if (a < b) __writeln(1); else __writeln(0);
    if (a != b) __writeln(1); else __writeln(0);
    double c = 3.14;
    if (a == c) __writeln(1); else __writeln(0);
    return 0;
}
