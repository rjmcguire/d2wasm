// EXPECTED: 55
int main() {
    int sum = 0;
    int i = 1;
    while (i <= 10) {
        sum += i;
        i++;
    }
    __writeln(sum);
    return 0;
}
