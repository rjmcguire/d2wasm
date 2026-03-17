// EXPECTED: 1
// EXPECTED: 0
// EXPECTED: 1
int main() {
    if (cast(bool)1) __writeln(1); else __writeln(0);
    if (cast(bool)0) __writeln(1); else __writeln(0);
    if (cast(bool)42) __writeln(1); else __writeln(0);
    return 0;
}
