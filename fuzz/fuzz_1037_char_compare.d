// EXPECTED: 1
// EXPECTED: 0
int main() {
    char a = 'z';
    char b = 'a';
    if (a > b) __writeln(1); else __writeln(0);
    if (a == b) __writeln(1); else __writeln(0);
    return 0;
}
