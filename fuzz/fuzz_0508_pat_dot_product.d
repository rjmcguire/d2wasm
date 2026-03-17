// EXPECTED: 32
int main() {
    int[3] a = [1, 2, 3];
    int[3] b = [4, 5, 6];
    int dot = 0;
    for (int i = 0; i < 3; i++) dot += a[i] * b[i];
    __writeln(dot);
    return 0;
}
