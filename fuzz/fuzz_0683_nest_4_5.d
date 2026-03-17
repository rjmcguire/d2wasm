// EXPECTED: 20
int main() {
    int count = 0;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 5; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
