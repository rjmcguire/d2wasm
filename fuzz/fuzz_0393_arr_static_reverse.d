// EXPECTED: 5
// EXPECTED: 4
// EXPECTED: 3
// EXPECTED: 2
// EXPECTED: 1
int main() {
    int[5] a = [1, 2, 3, 4, 5];
    for (int i = 4; i >= 0; i--) {
        __writeln(a[i]);
    }
    return 0;
}
