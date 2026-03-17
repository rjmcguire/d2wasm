// EXPECTED: 99
struct Holder(T) { T val; T get() { return val; } }

int main() {
    auto h = Holder!int(99);
    __writeln(h.get());
    return 0;
}
