/**
 * Milestone 173: Generate Itables
 * Tests that interface tables are generated correctly.
 * (Just verifies class methods still work - actual dispatch tested later)
 */
module test.itables;

interface ISpeak {
    int speak();
}

interface IWalk {
    int walk();
}

class Dog : ISpeak, IWalk {
    int speak() { return 10; }
    int walk() { return 20; }
}

class Cat : ISpeak {
    int speak() { return 100; }
}

int main() {
    Dog d;
    Cat c;
    return d.speak() + d.walk() + c.speak();  // 10 + 20 + 100 = 130
}
