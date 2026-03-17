// EXPECTED: 15
struct Counter {
    int value;

    int get() {
        return value;
    }
}

int main() {
    auto c = Counter(15);
    __writeln(c.get());
    return 0;
}
