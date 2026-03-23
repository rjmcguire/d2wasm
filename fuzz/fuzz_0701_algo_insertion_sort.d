// STATUS: maybeLater — foreach not parsed
// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
// EXPECTED: 4
// EXPECTED: 5
int main() {
    int[5] a = [5, 2, 4, 1, 3];
    for (int i = 1; i < 5; i++) {
        int key = a[i];
        int j = i - 1;
        while (j >= 0 && a[j] > key) {
            a[j + 1] = a[j];
            j--;
        }
        a[j + 1] = key;
    }
    foreach (v; a) __writeln(v);
    return 0;
}
