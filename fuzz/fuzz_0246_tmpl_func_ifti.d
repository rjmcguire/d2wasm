// EXPECTED: 8
T add(T)(T a, T b) {
    return a + b;
}

int main() {
    __writeln(add(3, 5));
    return 0;
}
