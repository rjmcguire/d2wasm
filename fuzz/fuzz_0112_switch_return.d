// STATUS: maybeLater — switch not parsed
// EXPECTED: 2
// EXPECTED: -1
int lookup(int x) {
    switch (x) {
        case 1: return 1;
        case 5: return 2;
        case 10: return 3;
        default: return -1;
    }
}

int main() {
    __writeln(lookup(5));
    __writeln(lookup(99));
    return 0;
}
