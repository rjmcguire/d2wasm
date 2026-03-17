// EXPECTED: 42
int main() {
    int x = 42;
    int* p = &x;
    __writeln(*p);
    return 0;
}
