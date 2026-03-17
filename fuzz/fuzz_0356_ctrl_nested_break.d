// EXPECTED: 6
int main() {
    int count = 0;
    for (int i = 0; i < 10; i++) {
        for (int j = 0; j < 10; j++) {
            if (j >= 3) break;
            count++;
        }
        if (i >= 1) break;
    }
    __writeln(count);
    return 0;
}
