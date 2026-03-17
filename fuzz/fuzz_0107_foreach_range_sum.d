// EXPECTED: 55
int main() {
    int sum = 0;
    foreach (i; 1 .. 11) {
        sum += i;
    }
    __writeln(sum);
    return 0;
}
