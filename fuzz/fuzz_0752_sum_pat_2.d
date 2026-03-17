// EXPECTED: 3
int main() {
    int s = 0;
    int i = 1;
    while (i <= 2) { s += i; i++; }
    __writeln(s);
    return 0;
}
