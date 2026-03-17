// EXPECTED: big
struct Size {
    int value;
}

int main() {
    auto s = Size(100);
    if (s.value > 50) __writeln("big");
    else __writeln("small");
    return 0;
}
