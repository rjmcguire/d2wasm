// EXPECTED: 10
int main() {
    int sum = 0;
    for (int i = 0; i < 5; i++)
        sum += i;
    __writeln(sum);
    return 0;
}
