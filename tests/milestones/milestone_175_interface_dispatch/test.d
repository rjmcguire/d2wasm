/**
 * Milestone 175: Interface Dispatch
 * Multiple classes implementing same interface, dispatch to correct impl.
 */
module test.interface_dispatch;

interface ISpeak {
    int speak();
}

class Dog : ISpeak {
    int speak() { return 10; }
}

class Cat : ISpeak {
    int speak() { return 20; }
}

int makeNoise(ISpeak s) {
    return s.speak();
}

int main() {
    Dog d;
    Cat c;
    return makeNoise(d) + makeNoise(c);  // 10 + 20 = 30
}
