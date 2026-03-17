// EXPECTED: 1
// EXPECTED: 1
// EXPECTED: 0
// EXPECTED: 1
int main() {
    if (-5 < 0) __writeln(1); else __writeln(0);
    if (-5 < 5) __writeln(1); else __writeln(0);
    if (-5 > 0) __writeln(1); else __writeln(0);
    if (-5 == -5) __writeln(1); else __writeln(0);
    return 0;
}
