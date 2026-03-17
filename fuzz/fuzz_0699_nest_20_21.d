// EXPECTED: 420
int main() {
    int count = 0;
    for (int i = 0; i < 20; i++) {
        for (int j = 0; j < 21; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
