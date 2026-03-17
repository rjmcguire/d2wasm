// EXPECTED: 7
T addTwo(T)(T x) { return x + 2; }

int main() {
    auto y = addTwo(addTwo(3));
    __writeln(y);
    return 0;
}
