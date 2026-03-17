// EXPECTED: 30
int main() {
    int count = 0;
    for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 6; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
