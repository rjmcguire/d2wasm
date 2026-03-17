// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
// EXPECTED: 4
int main() {
    int i = 0;
    while (i < 5) {
        __writeln(i);
        i++;
    }
    return 0;
}
