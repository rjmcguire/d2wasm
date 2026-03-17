// EXPECTED: hello from Base
class Base {
    void greet() {
        __writeln("hello from Base");
    }
}

class Derived : Base {
}

int main() {
    auto d = new Derived();
    d.greet();
    return 0;
}
