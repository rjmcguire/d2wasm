// EXPECTED: 12
int main() {
    int count = 0;
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 4; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
