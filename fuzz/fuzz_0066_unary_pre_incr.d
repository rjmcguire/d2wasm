// EXPECTED: 6
// EXPECTED: 6
int main() {
    int a = 5;
    ++a;
    __writeln(a);
    int b = 5;
    b++;
    __writeln(b);
    return 0;
}
