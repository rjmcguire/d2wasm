// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
// Value semantics: modifying param shouldn't affect caller
void modify(int[3] arr) {
    arr[0] = 99;
}

int main() {
    int[3] a = [1, 2, 3];
    modify(a);
    __writeln(a[0]);
    __writeln(a[1]);
    __writeln(a[2]);
    return 0;
}
