// EXPECTED: 5
int main() {
    int[] arr;
    for (int i = 0; i < 5; i++) {
        arr ~= i;
    }
    __writeln(arr.length);
    return 0;
}
