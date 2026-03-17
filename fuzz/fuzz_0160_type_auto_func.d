// EXPECTED: 100
int square(int x) {
    return x * x;
}

int main() {
    auto result = square(10);
    __writeln(result);
    return 0;
}
