// EXPECTED: 462
int main() {
    int count = 0;
    for (int i = 0; i < 21; i++) {
        for (int j = 0; j < 22; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
