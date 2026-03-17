// EXPECTED: 12
int double_(int x) { return x * 2; }
int addOne(int x) { return x + 1; }
int triple(int x) { return x * 3; }

int main() {
    // 1.addOne() = 2, .double_() = 4, .triple() = 12
    __writeln(1.addOne().double_().triple());
    return 0;
}
