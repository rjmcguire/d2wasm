// STATUS: maybeLater — foreach not parsed
// EXPECTED: 0:10
// EXPECTED: 1:20
// EXPECTED: 2:30
int main() {
    int[3] a = [10, 20, 30];
    foreach (i, v; a) {
        __writeln(__itos(i) ~ ":" ~ __itos(v));
    }
    return 0;
}
