// EXPECTED: 55
int main() {
    int sum = 0;
    for (int i = 1; i <= 10; i++) {
        sum += i;
    }
    __writeln(sum);
    return 0;
}
