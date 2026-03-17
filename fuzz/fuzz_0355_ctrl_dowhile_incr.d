// EXPECTED: 10
int main() {
    int x = 0;
    do { x += 2; } while (x < 10);
    __writeln(x);
    return 0;
}
