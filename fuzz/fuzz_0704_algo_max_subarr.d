// EXPECTED: 6
int main() {
    int[5] a = [-2, 1, -3, 4, 2];
    int maxSoFar = a[0];
    int maxHere = a[0];
    for (int i = 1; i < 5; i++) {
        if (a[i] > maxHere + a[i]) maxHere = a[i];
        else maxHere = maxHere + a[i];
        if (maxHere > maxSoFar) maxSoFar = maxHere;
    }
    __writeln(maxSoFar);
    return 0;
}
