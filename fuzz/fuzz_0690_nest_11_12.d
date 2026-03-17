// EXPECTED: 132
int main() {
    int count = 0;
    for (int i = 0; i < 11; i++) {
        for (int j = 0; j < 12; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
