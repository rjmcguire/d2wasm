// STATUS: bug — compile error
// EXPECTED: 50
int sumArr(int[5] arr) {
    int s = 0;
    for (int i = 0; i < 5; i++) s += arr[i];
    return s;
}

int main() {
    __writeln(sumArr([10, 10, 10, 10, 10]));
    return 0;
}
