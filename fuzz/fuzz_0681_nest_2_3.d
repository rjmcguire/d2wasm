// EXPECTED: 6
int main() {
    int count = 0;
    for (int i = 0; i < 2; i++) {
        for (int j = 0; j < 3; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
