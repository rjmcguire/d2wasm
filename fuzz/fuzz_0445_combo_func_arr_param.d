// EXPECTED: 3
int maxOf(int[4] arr) {
    int m = arr[0];
    for (int i = 1; i < 4; i++) if (arr[i] > m) m = arr[i];
    return m;
}

int main() {
    __writeln(maxOf([1, 3, 2, 0]));
    return 0;
}
