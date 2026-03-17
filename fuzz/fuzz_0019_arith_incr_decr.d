// EXPECTED: 6
// EXPECTED: 4
// EXPECTED: 4
int main() {
    int a = 5;
    a++;
    __writeln(a);
    a--;
    a--;
    __writeln(a);
    int b = 3;
    b++;
    __writeln(b);
    return 0;
}
