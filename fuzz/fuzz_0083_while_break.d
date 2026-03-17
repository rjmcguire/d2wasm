// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
int main() {
    int i = 0;
    while (i < 100) {
        if (i == 3) break;
        __writeln(i);
        i++;
    }
    return 0;
}
