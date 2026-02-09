/**
 * Milestone 172: Interface Type Checking
 * Verify class implements all interface methods.
 */
module test.interface_check;

interface ISpeak {
    int speak();
}

interface IWalk {
    int walk();
}

class Dog : ISpeak, IWalk {
    int speak() { return 1; }
    int walk() { return 2; }
}

int main() {
    Dog d;
    return d.speak() + d.walk();  // 1 + 2 = 3
}
