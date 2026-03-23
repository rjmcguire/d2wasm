// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
class A { int level() { return 1; } }
class B : A { override int level() { return 2; } }
class C : B { override int level() { return 3; } }

int main() {
    auto a = new A();
    auto b = new B();
    auto c = new C();
    __writeln(a.level());
    __writeln(b.level());
    __writeln(c.level());
    return 0;
}
