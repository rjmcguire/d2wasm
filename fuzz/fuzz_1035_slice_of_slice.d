// EXPECTED: 3
// EXPECTED: 4
int main() {
    int[6] a = [1, 2, 3, 4, 5, 6];
    auto s1 = a[1 .. 5];  // [2, 3, 4, 5]
    auto s2 = s1[1 .. 3]; // [3, 4]
    __writeln(s2[0]);
    __writeln(s2[1]);
    return 0;
}
