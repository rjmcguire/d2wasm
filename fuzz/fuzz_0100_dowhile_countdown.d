// EXPECTED: 3
// EXPECTED: 2
// EXPECTED: 1
int main() {
    int n = 3;
    do {
        __writeln(n);
        n--;
    } while (n > 0);
    return 0;
}
