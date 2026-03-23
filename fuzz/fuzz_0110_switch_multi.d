// STATUS: maybeLater — switch not parsed
// EXPECTED: small
// EXPECTED: small
// EXPECTED: big
int classify(int x) {
    switch (x) {
        case 1:
        case 2:
        case 3:
            __writeln("small");
            break;
        default:
            __writeln("big");
            break;
    }
    return 0;
}

int main() {
    classify(1);
    classify(3);
    classify(10);
    return 0;
}
