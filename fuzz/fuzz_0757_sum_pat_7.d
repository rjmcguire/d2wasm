// EXPECTED: 28
int main() {
    int s = 0;
    int i = 1;
    while (i <= 7) { s += i; i++; }
    __writeln(s);
    return 0;
}
