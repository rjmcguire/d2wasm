// EXPECTED: 1
// EXPECTED: 1
// EXPECTED: 1
int main() {
    int a = 5;
    long b = 5;
    if (a == cast(int)b) __writeln(1); else __writeln(0);
    short c = 5;
    if (a == cast(int)c) __writeln(1); else __writeln(0);
    byte d = 5;
    if (a == cast(int)d) __writeln(1); else __writeln(0);
    return 0;
}
