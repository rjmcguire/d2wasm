// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 3
class A {
    int level() { return 1; }
}
class B : A {
    override int level() { return 2; }
}
class C : B {
    override int level() { return 3; }
}

int main() {
    A c = new C();
    __writeln(c.level());
    return 0;
}
