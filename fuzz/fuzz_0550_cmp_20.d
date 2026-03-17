// EXPECTED: 1
int main() {
    if (100 != 99) __writeln(1); else __writeln(0);
    return 0;
}
