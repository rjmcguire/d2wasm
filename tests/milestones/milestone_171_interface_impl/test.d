/**
 * Milestone 171: Parse Interface Implementation
 */
module test.interface_impl;

interface ISpeak {
    int speak();
}

class Animal {
    int age;
}

class Dog : Animal, ISpeak {
    int barkCount;
    
    int speak() {
        return 42;
    }
}

int main() {
    Dog d;
    return d.speak();  // 42
}
