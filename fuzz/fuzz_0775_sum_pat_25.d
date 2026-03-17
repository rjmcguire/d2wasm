// EXPECTED: 325
int main() {
    int s = 0;
    int i = 1;
    while (i <= 25) { s += i; i++; }
    __writeln(s);
    return 0;
}
