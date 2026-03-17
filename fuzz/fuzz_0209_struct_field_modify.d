// EXPECTED: 42
struct Box {
    int value;
}

int main() {
    auto b = Box(0);
    b.value = 42;
    __writeln(b.value);
    return 0;
}
