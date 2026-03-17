// EXPECTED: 105
int main() {
    int s = 0;
    int i = 1;
    while (i <= 14) { s += i; i++; }
    __writeln(s);
    return 0;
}
