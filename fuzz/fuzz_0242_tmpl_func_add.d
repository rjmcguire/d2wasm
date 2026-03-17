// EXPECTED: 15
T add(T)(T a, T b) {
    return a + b;
}

int main() {
    __writeln(add!int(7, 8));
    return 0;
}
