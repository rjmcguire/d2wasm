// EXPECTED: 3
// EXPECTED: 10
// EXPECTED: 20
// EXPECTED: 30
int main() {
    int[] arr;
    arr ~= 10;
    arr ~= 20;
    arr ~= 30;
    __writeln(arr.length);
    __writeln(arr[0]);
    __writeln(arr[1]);
    __writeln(arr[2]);
    return 0;
}
