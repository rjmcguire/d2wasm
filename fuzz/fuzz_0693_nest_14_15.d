// EXPECTED: 210
int main() {
    int count = 0;
    for (int i = 0; i < 14; i++) {
        for (int j = 0; j < 15; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
