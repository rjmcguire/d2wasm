// EXPECTED: 2147483647
// EXPECTED: 1
int main() {
    int a = -2;
    __writeln(a >>> 1);
    __writeln(4 >>> 2);
    return 0;
}
