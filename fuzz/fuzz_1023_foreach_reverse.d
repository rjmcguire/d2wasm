// STATUS: maybeLater — foreach not parsed
// EXPECTED: 3
// EXPECTED: 2
// EXPECTED: 1
int main() {
    int[3] a = [1, 2, 3];
    foreach_reverse (v; a) {
        __writeln(v);
    }
    return 0;
}
