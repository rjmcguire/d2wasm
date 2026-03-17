// EXPECTED: 42
int main() {
    int* p = new int;
    *p = 42;
    __writeln(*p);
    return 0;
}
