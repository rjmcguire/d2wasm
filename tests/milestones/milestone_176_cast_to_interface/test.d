/**
 * Milestone 176: Cast to interface
 * Explicit cast from class to interface creates fat pointer.
 */
module test.cast_to_interface;

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
    // Explicit casts should work just like implicit conversion
    return makeNoise(cast(ISpeak)d) + makeNoise(cast(ISpeak)c);  // 10 + 20 = 30
}
