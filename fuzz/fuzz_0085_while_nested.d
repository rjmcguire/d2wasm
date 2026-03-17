// EXPECTED: 0
// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
int main() {
    int i = 0;
    while (i < 2) {
        int j = 0;
        while (j < 2) {
            __writeln(i * 2 + j);
            j++;
        }
        i++;
    }
    return 0;
}
