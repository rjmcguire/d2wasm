// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
int main() {
    int[3] a = [3, 1, 2];
    for (int i = 0; i < 3; i++) {
        int mi = i;
        for (int j = i + 1; j < 3; j++) {
            if (a[j] < a[mi]) mi = j;
        }
        int tmp = a[i]; a[i] = a[mi]; a[mi] = tmp;
    }
    foreach (v; a) __writeln(v);
    return 0;
}
