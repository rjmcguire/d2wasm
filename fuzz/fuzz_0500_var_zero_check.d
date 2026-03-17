// EXPECTED: 1
// EXPECTED: 0
int main() {
    int a = 0;
    if (a == 0) __writeln(1); else __writeln(0);
    a = 1;
    if (a == 0) __writeln(1); else __writeln(0);
    return 0;
}
