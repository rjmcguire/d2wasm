// EXPECTED: 1
// EXPECTED: 1
// EXPECTED: 1
// EXPECTED: 0
int main() {
    if (true || true) __writeln(1); else __writeln(0);
    if (true || false) __writeln(1); else __writeln(0);
    if (false || true) __writeln(1); else __writeln(0);
    if (false || false) __writeln(1); else __writeln(0);
    return 0;
}
