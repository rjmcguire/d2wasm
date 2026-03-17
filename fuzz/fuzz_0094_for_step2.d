// EXPECTED: 0
// EXPECTED: 2
// EXPECTED: 4
// EXPECTED: 6
// EXPECTED: 8
int main() {
    for (int i = 0; i < 10; i += 2) {
        __writeln(i);
    }
    return 0;
}
