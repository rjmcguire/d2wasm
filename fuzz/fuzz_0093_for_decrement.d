// EXPECTED: 5
// EXPECTED: 4
// EXPECTED: 3
// EXPECTED: 2
// EXPECTED: 1
int main() {
    for (int i = 5; i >= 1; i--) {
        __writeln(i);
    }
    return 0;
}
