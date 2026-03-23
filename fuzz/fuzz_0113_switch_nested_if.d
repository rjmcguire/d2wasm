// STATUS: maybeLater — switch not parsed
// EXPECTED: even-two
int main() {
    int x = 2;
    switch (x) {
        case 1:
            __writeln("one");
            break;
        case 2:
            if (x % 2 == 0) __writeln("even-two");
            else __writeln("odd-two");
            break;
        default:
            __writeln("other");
            break;
    }
    return 0;
}
