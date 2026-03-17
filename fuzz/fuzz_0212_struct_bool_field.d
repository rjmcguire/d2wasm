// EXPECTED: 1
// EXPECTED: 0
struct Flags {
    bool active;
    bool visible;
}

int main() {
    auto f = Flags(true, false);
    if (f.active) __writeln(1); else __writeln(0);
    if (f.visible) __writeln(1); else __writeln(0);
    return 0;
}
