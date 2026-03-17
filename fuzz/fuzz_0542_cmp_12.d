// EXPECTED: 1
int main() {
    if (3 != 4) __writeln(1); else __writeln(0);
    return 0;
}
