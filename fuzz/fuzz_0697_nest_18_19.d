// EXPECTED: 342
int main() {
    int count = 0;
    for (int i = 0; i < 18; i++) {
        for (int j = 0; j < 19; j++) {
            count++;
        }
    }
    __writeln(count);
    return 0;
}
