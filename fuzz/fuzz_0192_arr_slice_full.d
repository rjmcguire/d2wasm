// STATUS: maybeLater — dollar not implemented
// EXPECTED: 3
int main() {
    int[3] arr = [1, 2, 3];
    auto s = arr[0 .. $];
    __writeln(s.length);
    return 0;
}
