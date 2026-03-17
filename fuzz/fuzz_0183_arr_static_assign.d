// EXPECTED: 99
// EXPECTED: 2
// EXPECTED: 3
int main() {
    int[3] arr = [1, 2, 3];
    arr[0] = 99;
    __writeln(arr[0]);
    __writeln(arr[1]);
    __writeln(arr[2]);
    return 0;
}
