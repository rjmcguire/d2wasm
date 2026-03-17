// EXPECTED: 10
// EXPECTED: 20
class Base {
    int val() { return 10; }
}

class D1 : Base {
    override int val() { return 20; }
}

int main() {
    auto b = new Base();
    auto d = new D1();
    __writeln(b.val());
    __writeln(d.val());
    return 0;
}
