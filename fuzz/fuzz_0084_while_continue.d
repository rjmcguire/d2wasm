// EXPECTED: 1
// EXPECTED: 3
// EXPECTED: 5
// EXPECTED: 7
// EXPECTED: 9
int main() {
    int i = 0;
    while (i < 10) {
        i++;
        if (i % 2 == 0) continue;
        __writeln(i);
    }
    return 0;
}
