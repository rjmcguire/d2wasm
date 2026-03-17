// EXPECTED: two
int main() {
    int x = 2;
    switch (x) {
        case 1:
            __writeln("one");
            break;
        case 2:
            __writeln("two");
            break;
        case 3:
            __writeln("three");
            break;
        default:
            __writeln("other");
            break;
    }
    return 0;
}
