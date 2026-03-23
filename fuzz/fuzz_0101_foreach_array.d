// STATUS: maybeLater — foreach not parsed
// EXPECTED: 10
// EXPECTED: 20
// EXPECTED: 30
int main() {
    int[3] arr = [10, 20, 30];
    foreach (val; arr) {
        __writeln(val);
    }
    return 0;
}
