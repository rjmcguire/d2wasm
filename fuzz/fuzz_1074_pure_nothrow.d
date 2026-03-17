// EXPECTED: 25
pure nothrow int square(int x) {
    return x * x;
}

int main() {
    __writeln(square(5));
    return 0;
}
