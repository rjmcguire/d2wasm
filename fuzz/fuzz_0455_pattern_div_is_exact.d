// EXPECTED: 1
// EXPECTED: 0
int main() {
    if (10 % 5 == 0) __writeln(1); else __writeln(0);
    if (10 % 3 == 0) __writeln(1); else __writeln(0);
    return 0;
}
