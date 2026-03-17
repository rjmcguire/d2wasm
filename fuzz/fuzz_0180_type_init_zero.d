// EXPECTED: 0
// EXPECTED: 0
int main() {
    int a;
    __writeln(a);
    bool b;
    if (b) __writeln(1); else __writeln(0);
    return 0;
}
