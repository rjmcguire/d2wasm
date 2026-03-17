// EXPECTED: 5
// EXPECTED: 4
// EXPECTED: 3
// EXPECTED: 2
// EXPECTED: 1
int main() {
    int n = 5;
    while (n > 0) {
        __writeln(n);
        n--;
    }
    return 0;
}
