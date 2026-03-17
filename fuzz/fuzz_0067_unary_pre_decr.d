// EXPECTED: 4
// EXPECTED: 4
int main() {
    int a = 5;
    --a;
    __writeln(a);
    int b = 5;
    b--;
    __writeln(b);
    return 0;
}
