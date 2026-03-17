// EXPECTED: 1
int main() {
    if (0 == 0) __writeln(1); else __writeln(0);
    return 0;
}
