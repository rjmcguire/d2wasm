// EXPECTED: 561
int main() {
    int s = 0;
    int i = 1;
    while (i <= 33) { s += i; i++; }
    __writeln(s);
    return 0;
}
