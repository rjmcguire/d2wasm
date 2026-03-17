// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
int main() {
    for (int i = 0; i < 100; i++) {
        if (i == 3) break;
        __writeln(i);
    }
    return 0;
}
