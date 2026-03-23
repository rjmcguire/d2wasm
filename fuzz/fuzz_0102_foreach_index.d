// STATUS: maybeLater — foreach not parsed
// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
int main() {
    int[3] arr = [10, 20, 30];
    foreach (i, val; arr) {
        __writeln(i);
    }
    return 0;
}
