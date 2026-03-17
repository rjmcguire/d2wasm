// EXPECTED: 1
struct V { int x; }

int main() {
    auto a = V(10);
    auto b = V(20);
    if (a.x < b.x) __writeln(1); else __writeln(0);
    return 0;
}
