// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 100
class Base {
    int compute() { return 10; }
}

class Derived : Base {
    override int compute() { return 100; }
}

int main() {
    Base b = new Derived();
    __writeln(b.compute());
    return 0;
}
