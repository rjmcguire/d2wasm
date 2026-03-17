// EXPECTED: 100
int main() {
    int s = 0;
    int i = 0;
    while (i < 100) { s++; i++; }
    __writeln(s);
    return 0;
}
