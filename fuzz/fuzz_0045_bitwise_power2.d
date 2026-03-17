// EXPECTED: 1
// EXPECTED: 1
// EXPECTED: 0
// EXPECTED: 0
int main() {
    int a = 16;
    if ((a & (a - 1)) == 0) __writeln(1); else __writeln(0);
    a = 1;
    if ((a & (a - 1)) == 0) __writeln(1); else __writeln(0);
    a = 6;
    if ((a & (a - 1)) == 0) __writeln(1); else __writeln(0);
    a = 15;
    if ((a & (a - 1)) == 0) __writeln(1); else __writeln(0);
    return 0;
}
