// STATUS: maybeLater — foreach not parsed
// EXPECTED: 21
int main() {
    int[6] a = [1, 2, 3, 4, 5, 6];
    int s = 0;
    foreach (v; a) s += v;
    __writeln(s);
    return 0;
}
