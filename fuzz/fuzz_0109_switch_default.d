// EXPECTED: other
int main() {
    int x = 99;
    switch (x) {
        case 1:
            __writeln("one");
            break;
        case 2:
            __writeln("two");
            break;
        default:
            __writeln("other");
            break;
    }
    return 0;
}
