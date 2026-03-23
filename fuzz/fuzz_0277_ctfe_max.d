// STATUS: maybeLater — ternary not parsed
// EXPECTED: 20
int myMax(int a, int b) {
    return a > b ? a : b;
}

enum m = myMax(10, 20);

int main() {
    __writeln(m);
    return 0;
}
