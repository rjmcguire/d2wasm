// STATUS: maybeLater — do-while not parsed
// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
int main() {
    int i = 0;
    do {
        __writeln(i);
        i++;
    } while (i < 3);
    return 0;
}
