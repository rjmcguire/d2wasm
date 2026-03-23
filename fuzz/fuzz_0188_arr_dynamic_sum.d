// STATUS: maybeLater — foreach not parsed
// EXPECTED: 45
int main() {
    int[] arr;
    for (int i = 0; i < 10; i++) {
        arr ~= i;
    }
    int sum = 0;
    foreach (val; arr) {
        sum += val;
    }
    __writeln(sum);
    return 0;
}
