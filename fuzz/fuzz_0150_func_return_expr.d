// EXPECTED: 30
int compute(int x) {
    return (x + 5) * (x - 5);
}

int main() {
    __writeln(compute(7));
    return 0;
}
