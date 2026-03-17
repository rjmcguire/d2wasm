// EXPECTED: 6
struct Wrapper(T) {
    T value;

    T tripled() {
        return value + value + value;
    }
}

int main() {
    auto w = Wrapper!int(2);
    __writeln(w.tripled());
    return 0;
}
