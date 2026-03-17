// EXPECTED: 1
// EXPECTED: 0
int main() {
    bool x = 5 > 3;
    if (x) __writeln(1); else __writeln(0);
    bool y = 5 < 3;
    if (y) __writeln(1); else __writeln(0);
    return 0;
}
