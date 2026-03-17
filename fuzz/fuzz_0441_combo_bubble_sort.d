// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
// EXPECTED: 4
// EXPECTED: 5
int main() {
    int[5] a = [5, 3, 1, 4, 2];
    for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 4 - i; j++) {
            if (a[j] > a[j + 1]) {
                int tmp = a[j];
                a[j] = a[j + 1];
                a[j + 1] = tmp;
            }
        }
    }
    foreach (v; a) __writeln(v);
    return 0;
}
