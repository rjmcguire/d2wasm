// EXPECTED: 380
int main() {
    int count = 0;
    for (int i = 0; i < 19; i++) {
        for (int j = 0; j < 20; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
