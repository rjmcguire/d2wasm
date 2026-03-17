// EXPECTED: 1
// EXPECTED: 1
int main() {
    bool a = true;
    bool b = false;
    if (a && !b) __writeln(1); else __writeln(0);
    if (a || b) __writeln(1); else __writeln(0);
    return 0;
}
