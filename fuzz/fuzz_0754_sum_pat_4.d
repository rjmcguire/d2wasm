// EXPECTED: 10
int main() {
    int s = 0;
    int i = 1;
    while (i <= 4) { s += i; i++; }
    __writeln(s);
    return 0;
}
