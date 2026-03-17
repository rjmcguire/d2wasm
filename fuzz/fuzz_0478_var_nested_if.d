// EXPECTED: c
int main() {
    int x = 30;
    if (x > 100) __writeln("a");
    else if (x > 50) __writeln("b");
    else if (x > 20) __writeln("c");
    else __writeln("d");
    return 0;
}
