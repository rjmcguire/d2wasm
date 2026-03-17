// EXPECTED: 1
// EXPECTED: 1
// EXPECTED: 0
int main() {
    if (3 > 2 && 5 > 4) __writeln(1); else __writeln(0);
    if (3 > 2 || 5 < 4) __writeln(1); else __writeln(0);
    if (!(3 > 2) && 5 > 4) __writeln(1); else __writeln(0);
    return 0;
}
