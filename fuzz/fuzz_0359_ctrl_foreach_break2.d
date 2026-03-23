// STATUS: maybeLater — foreach not parsed
// EXPECTED: 10
int main() {
    int[10] arr = [1,2,3,4,5,6,7,8,9,10];
    int sum = 0;
    foreach (v; arr) {
        sum += v;
        if (sum >= 10) break;
    }
    __writeln(sum);
    return 0;
}
