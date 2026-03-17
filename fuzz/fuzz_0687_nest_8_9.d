// EXPECTED: 72
int main() {
    int count = 0;
    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 9; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
