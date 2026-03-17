// EXPECTED: 14
int main() {
    int total = 0;
    int i = 0;
    while (i < 3) {
        for (int j = 0; j < i + 1; j++) {
            total += j + i;
        }
        i++;
    }
    __writeln(total);
    return 0;
}
