// EXPECTED: 90
int main() {
    int count = 0;
    for (int i = 0; i < 9; i++) {
        for (int j = 0; j < 10; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
