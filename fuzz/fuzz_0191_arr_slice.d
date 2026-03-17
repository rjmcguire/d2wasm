// EXPECTED: 2
// EXPECTED: 20
// EXPECTED: 30
int main() {
    int[5] arr = [10, 20, 30, 40, 50];
    auto s = arr[1 .. 3];
    __writeln(s.length);
    __writeln(s[0]);
    __writeln(s[1]);
    return 0;
}
