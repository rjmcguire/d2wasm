// EXPECTED: 1024
int main() {
    int x = 1;
    int i = 0;
    while (i < 10) { x *= 2; i++; }
    __writeln(x);
    return 0;
}
