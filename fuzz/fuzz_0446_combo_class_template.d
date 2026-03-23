// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 42
class Holder(T) {
    T val;
    this(T v) { val = v; }
    T get() { return val; }
}

int main() {
    auto h = new Holder!int(42);
    __writeln(h.get());
    return 0;
}
