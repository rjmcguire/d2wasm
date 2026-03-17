// EXPECTED: 42
int main() {
    int x = mixin("40 + 2");
    __writeln(x);
    return 0;
}
