// EXPECTED: 1
// EXPECTED: 0
int main() {
    if (42 % 2 == 0) __writeln(1); else __writeln(0);
    if (43 % 2 == 0) __writeln(1); else __writeln(0);
    return 0;
}
