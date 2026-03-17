// EXPECTED: 10
// EXPECTED: 99
struct Val {
    int x;
}

int main() {
    auto a = Val(10);
    auto b = a;
    b.x = 99;
    __writeln(a.x);
    __writeln(b.x);
    return 0;
}
