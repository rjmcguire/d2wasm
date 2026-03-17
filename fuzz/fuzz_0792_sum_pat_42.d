// EXPECTED: 903
int main() {
    int s = 0;
    int i = 1;
    while (i <= 42) { s += i; i++; }
    __writeln(s);
    return 0;
}
