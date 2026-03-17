// EXPECTED: 0
// EXPECTED: 0
class D {
    int x;
    int y;
}

int main() {
    auto d = new D();
    __writeln(d.x);
    __writeln(d.y);
    return 0;
}
