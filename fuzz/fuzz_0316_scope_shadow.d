// EXPECTED: 10
// EXPECTED: 20
// EXPECTED: 10
int main() {
    int x = 10;
    __writeln(x);
    {
        int x = 20;
        __writeln(x);
    }
    __writeln(x);
    return 0;
}
