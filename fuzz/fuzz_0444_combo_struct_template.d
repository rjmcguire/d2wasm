// EXPECTED: 10
struct Box(T) { T val; T get() { return val; } }

int main() {
    auto b = Box!int(10);
    __writeln(b.get());
    return 0;
}
