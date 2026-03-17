// EXPECTED: 171
int main() {
    int s = 0;
    int i = 1;
    while (i <= 18) { s += i; i++; }
    __writeln(s);
    return 0;
}
