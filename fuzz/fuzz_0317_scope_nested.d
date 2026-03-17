// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
int main() {
    int a = 1;
    __writeln(a);
    {
        int b = 2;
        __writeln(b);
        {
            int c = 3;
            __writeln(c);
        }
    }
    return 0;
}
