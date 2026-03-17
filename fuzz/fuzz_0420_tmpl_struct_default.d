// EXPECTED: 0
struct Box(T) { T val; T get() { return val; } }

int main() {
    Box!int b;
    __writeln(b.get());
    return 0;
}
