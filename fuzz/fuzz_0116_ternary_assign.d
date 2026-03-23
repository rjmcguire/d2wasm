// STATUS: maybeLater — ternary not parsed
// EXPECTED: 1
// EXPECTED: 0
int main() {
    bool flag = true;
    int val = flag ? 1 : 0;
    __writeln(val);
    flag = false;
    val = flag ? 1 : 0;
    __writeln(val);
    return 0;
}
