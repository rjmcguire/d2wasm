// EXPECTED: 10
// EXPECTED: 20
struct A {
    int x;
}

struct B {
    int y;
}

int main() {
    auto a = A(10);
    auto b = B(20);
    __writeln(a.x);
    __writeln(b.y);
    return 0;
}
