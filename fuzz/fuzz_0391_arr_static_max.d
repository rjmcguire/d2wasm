// EXPECTED: 50
int main() {
    int[5] a = [10, 50, 30, 20, 40];
    int m = a[0];
    for (int i = 1; i < 5; i++) {
        if (a[i] > m) m = a[i];
    }
    __writeln(m);
    return 0;
}
