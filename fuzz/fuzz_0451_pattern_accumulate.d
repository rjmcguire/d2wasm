// STATUS: bug — wrong output
// EXPECTED: 285
int main() {
    int sum = 0;
    for (int i = 1; i <= 10; i++) sum += i * i;
    __writeln(sum);
    return 0;
}
