// EXPECTED: 1
int main() {
    int[3] a = [1, 2, 3];
    auto p = a.ptr;
    __writeln(*p);
    return 0;
}
