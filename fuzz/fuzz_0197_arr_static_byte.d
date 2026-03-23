// STATUS: maybeLater — literal narrowing not implemented
// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
int main() {
    byte[3] arr = [1, 2, 3];
    __writeln(arr[0]);
    __writeln(arr[1]);
    __writeln(arr[2]);
    return 0;
}
