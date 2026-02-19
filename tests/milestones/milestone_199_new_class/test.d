class Dog {
    int age;
    int weight;
}

class Counter {
    int value;

    this(int initial) {
        value = initial * 2;
    }

    int get() { return value; }
}

int main() @gc(heap) {
    // Test 1: basic class new (no constructor)
    Dog* d = new Dog(5, 30);
    int r1 = d.age + d.weight;  // expect 35

    // Test 2: class new with constructor
    Counter* c = new Counter(10);
    int r2 = c.get();  // expect 20

    // Test 3: class new with zero args (zero-init)
    Dog* d2 = new Dog();
    int r3 = d2.age + d2.weight;  // expect 0

    return r1 + r2 + r3;  // expect 55
}
