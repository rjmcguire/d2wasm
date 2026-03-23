// STATUS: maybeLater — nested functions not parsed
// EXPECTED: 7
int main() {
    int add(int a, int b) {
        return a + b;
    }
    int mul(int a, int b) {
        return a * b;
    }
    __writeln(add(mul(2, 3), 1));
    return 0;
}
