// EXPECTED: 42
struct Box(T) {
    T value;

    T get() {
        return value;
    }
}

int main() {
    auto b = Box!int(42);
    __writeln(b.get());
    return 0;
}
