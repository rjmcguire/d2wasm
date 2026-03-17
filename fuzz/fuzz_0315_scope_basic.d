// EXPECTED: 10
// EXPECTED: 20
int main() {
    int x = 10;
    __writeln(x);
    {
        int y = 20;
        __writeln(y);
    }
    return 0;
}
