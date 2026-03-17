// EXPECTED: 1176
int main() {
    int s = 0;
    int i = 1;
    while (i <= 48) { s += i; i++; }
    __writeln(s);
    return 0;
}
