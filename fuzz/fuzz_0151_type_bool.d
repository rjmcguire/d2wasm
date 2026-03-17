// EXPECTED: 1
// EXPECTED: 0
int main() {
    bool t = true;
    bool f = false;
    if (t) __writeln(1); else __writeln(0);
    if (f) __writeln(1); else __writeln(0);
    return 0;
}
