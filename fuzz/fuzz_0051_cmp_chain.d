// EXPECTED: 1
// EXPECTED: 0
// EXPECTED: 1
int main() {
    int a = 5;
    int b = 10;
    int c = 15;
    if (a < b && b < c) __writeln(1); else __writeln(0);
    if (a > b && b < c) __writeln(1); else __writeln(0);
    if (a < b || b > c) __writeln(1); else __writeln(0);
    return 0;
}
