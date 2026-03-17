// EXPECTED: 42
// EXPECTED: 100
struct Box(T) {
    T value;
    T get() { return value; }
}

int main() {
    auto a = Box!int(42);
    auto b = Box!int(100);
    __writeln(a.get());
    __writeln(b.get());
    return 0;
}
