// EXPECTED: 3
// Could test multiple declarators: int a = 1, b = 2;
int main() {
    int a = 1;
    int b = 2;
    __writeln(a + b);
    return 0;
}
