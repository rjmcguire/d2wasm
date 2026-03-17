// EXPECTED: 81
int main() {
    int r = 1;
    int i = 0;
    while (i < 4) { r *= 3; i++; }
    __writeln(r);
    return 0;
}
