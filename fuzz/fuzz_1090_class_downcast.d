// STATUS: wontfix — new requires @gc annotation
// EXPECTED: dog
class Animal {
    string type() { return "animal"; }
}

class Dog : Animal {
    override string type() { return "dog"; }
    void bark() { __writeln("woof"); }
}

int main() {
    Animal a = new Dog();
    // Virtual dispatch
    __writeln(a.type());
    return 0;
}
