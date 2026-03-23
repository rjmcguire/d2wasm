// STATUS: wontfix — new requires @gc annotation
// EXPECTED: cat
// EXPECTED: dog
class Animal {
    void speak() { __writeln("animal"); }
}

class Cat : Animal {
    override void speak() { __writeln("cat"); }
}

class Dog : Animal {
    override void speak() { __writeln("dog"); }
}

int main() {
    auto c = new Cat();
    auto d = new Dog();
    c.speak();
    d.speak();
    return 0;
}
