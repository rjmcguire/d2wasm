// STATUS: wontfix — new requires @gc annotation
// EXPECTED: hello from Derived
class Base {
    void greet() {
        __writeln("hello from Base");
    }
}

class Derived : Base {
    override void greet() {
        __writeln("hello from Derived");
    }
}

int main() {
    auto d = new Derived();
    d.greet();
    return 0;
}
