// EXPECTED: 15
// EXPECTED: 50
int scale(int x, int factor = 5) {
    return x * factor;
}

int main() {
    __writeln(scale(3));
    __writeln(scale(5, 10));
    return 0;
}
