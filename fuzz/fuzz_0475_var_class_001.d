// EXPECTED: 50
class V {
    int x;
    this(int x) { this.x = x; }
}

int main() {
    auto v = new V(50);
    __writeln(v.x);
    return 0;
}
