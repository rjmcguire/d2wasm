// EXPECTED: 42
int main() {
    int count = 0;
    for (int i = 0; i < 6; i++) {
        for (int j = 0; j < 7; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
