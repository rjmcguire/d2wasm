// EXPECTED: 30
int main() {
    int double_(int x) { return x * 2; }
    int triple(int x) { return x * 3; }
    __writeln(double_(triple(5)));
    return 0;
}
