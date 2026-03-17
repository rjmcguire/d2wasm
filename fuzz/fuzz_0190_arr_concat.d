// EXPECTED: 4
int main() {
    int[] a;
    a ~= 1;
    a ~= 2;
    int[] b;
    b ~= 3;
    b ~= 4;
    auto c = a ~ b;
    __writeln(c.length);
    return 0;
}
