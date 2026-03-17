// EXPECTED: 42
struct Wrapper {
    int value;
    alias this = value;
}

int main() {
    Wrapper w;
    w.value = 42;
    int x = w;
    __writeln(x);
    return 0;
}
