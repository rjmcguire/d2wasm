// EXPECTED: 1
int main() {
    bool a = 5 > 3;
    bool b = 10 > 5;
    if (a && b) __writeln(1); else __writeln(0);
    return 0;
}
