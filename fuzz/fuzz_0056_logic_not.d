// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 1
// EXPECTED: 0
int main() {
    if (!true) __writeln(1); else __writeln(0);
    if (!false) __writeln(1); else __writeln(0);
    if (!(3 < 2)) __writeln(1); else __writeln(0);
    if (!(3 > 2)) __writeln(1); else __writeln(0);
    return 0;
}
