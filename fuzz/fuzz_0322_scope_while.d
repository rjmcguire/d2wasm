// EXPECTED: 3
int main() {
    int sum = 0;
    int i = 0;
    while (i < 3) {
        int x = 1;
        sum += x;
        i++;
    }
    __writeln(sum);
    return 0;
}
