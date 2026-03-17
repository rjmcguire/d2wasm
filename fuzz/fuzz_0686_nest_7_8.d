// EXPECTED: 56
int main() {
    int count = 0;
    for (int i = 0; i < 7; i++) {
        for (int j = 0; j < 8; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
