// STATUS: maybeLater — foreach not parsed
// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
// EXPECTED: 4
int main() {
    foreach (i; 0 .. 5) {
        __writeln(i);
    }
    return 0;
}
