// EXPECTED: 630
int main() {
    int s = 0;
    int i = 1;
    while (i <= 35) { s += i; i++; }
    __writeln(s);
    return 0;
}
