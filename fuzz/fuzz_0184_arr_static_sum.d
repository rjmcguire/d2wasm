// EXPECTED: 15
int main() {
    int[5] arr = [1, 2, 3, 4, 5];
    int sum = 0;
    for (int i = 0; i < 5; i++) {
        sum += arr[i];
    }
    __writeln(sum);
    return 0;
}
