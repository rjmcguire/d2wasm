// STATUS: maybeLater — foreach not parsed
// EXPECTED: 150
int main() {
    int[5] arr = [10, 20, 30, 40, 50];
    int sum = 0;
    foreach (val; arr) {
        sum += val;
    }
    __writeln(sum);
    return 0;
}
