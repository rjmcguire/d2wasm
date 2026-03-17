// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
// EXPECTED: 4
int main() {
    for (int i = 0; i < 5; i++) {
        __writeln(i);
    }
    return 0;
}
