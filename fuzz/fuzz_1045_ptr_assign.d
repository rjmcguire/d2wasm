// EXPECTED: 99
int main() {
    int x = 0;
    int* p = &x;
    *p = 99;
    __writeln(x);
    return 0;
}
