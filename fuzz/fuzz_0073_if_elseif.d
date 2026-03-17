// EXPECTED: two
int main() {
    int x = 2;
    if (x == 1) __writeln("one");
    else if (x == 2) __writeln("two");
    else if (x == 3) __writeln("three");
    else __writeln("other");
    return 0;
}
