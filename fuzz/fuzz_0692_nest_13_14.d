// EXPECTED: 182
int main() {
    int count = 0;
    for (int i = 0; i < 13; i++) {
        for (int j = 0; j < 14; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
