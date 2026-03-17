// EXPECTED: 5000000000
struct BigVal {
    long value;
}

int main() {
    auto b = BigVal(5000000000);
    __writeln(b.value);
    return 0;
}
