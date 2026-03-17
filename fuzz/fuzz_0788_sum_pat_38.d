// EXPECTED: 741
int main() {
    int s = 0;
    int i = 1;
    while (i <= 38) { s += i; i++; }
    __writeln(s);
    return 0;
}
