// EXPECTED: 42
@trusted int getValue() {
    return 42;
}

int main() {
    __writeln(getValue());
    return 0;
}
