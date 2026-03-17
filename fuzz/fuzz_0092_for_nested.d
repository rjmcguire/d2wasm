// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
// EXPECTED: 2
// EXPECTED: 4
// EXPECTED: 6
// EXPECTED: 3
// EXPECTED: 6
// EXPECTED: 9
int main() {
    for (int i = 1; i <= 3; i++) {
        for (int j = 1; j <= 3; j++) {
            __writeln(i * j);
        }
    }
    return 0;
}
