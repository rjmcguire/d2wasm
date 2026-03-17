// EXPECTED: 25
int main() {
    int sum = 0;
    for (int i = 0; i < 10; i++) {
        sum += (i % 2 == 0) ? i : 0;
    }
    __writeln(sum - 5);
    return 0;
}
