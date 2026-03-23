// STATUS: maybeLater — feature not implemented
// EXPECTED: ok
version(none) {
    int main() { __writeln("bad"); return 0; }
} else {
    int main() { __writeln("ok"); return 0; }
}
