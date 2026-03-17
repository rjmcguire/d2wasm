// EXPECTED: 5
int main() {
    int[10] a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    int count = 0;
    foreach (v; a) {
        if (v > 5) count++;
    }
    __writeln(count);
    return 0;
}
