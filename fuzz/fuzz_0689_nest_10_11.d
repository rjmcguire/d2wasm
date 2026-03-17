// EXPECTED: 110
int main() {
    int count = 0;
    for (int i = 0; i < 10; i++) {
        for (int j = 0; j < 11; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
