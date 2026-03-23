// STATUS: maybeLater — foreach not parsed
// EXPECTED: 2
// EXPECTED: 4
// EXPECTED: 6
int main() {
    int[3] arr = [1, 2, 3];
    foreach (val; arr) {
        __writeln(val * 2);
    }
    return 0;
}
