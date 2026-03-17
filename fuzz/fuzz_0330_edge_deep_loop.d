// EXPECTED: 1000
int main() {
    int count = 0;
    for (int i = 0; i < 10; i++) {
        for (int j = 0; j < 10; j++) {
            for (int k = 0; k < 10; k++) {
                count++;
            }
        }
    }
    __writeln(count);
    return 0;
}
