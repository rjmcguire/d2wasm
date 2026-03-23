// STATUS: maybeLater — foreach not parsed
// EXPECTED: a
// EXPECTED: b
// EXPECTED: c
int main() {
    string[3] arr = ["a", "b", "c"];
    foreach (s; arr) __writeln(s);
    return 0;
}
