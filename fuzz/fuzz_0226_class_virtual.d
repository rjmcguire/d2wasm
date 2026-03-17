// EXPECTED: dog
class Animal {
    void speak() {
        __writeln("animal");
    }
}

class Dog : Animal {
    override void speak() {
        __writeln("dog");
    }
}

int main() {
    Animal a = new Dog();
    a.speak();
    return 0;
}
