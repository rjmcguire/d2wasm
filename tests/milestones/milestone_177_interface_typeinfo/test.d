/**
 * Milestone 177: Interface TypeInfo
 * Interface TypeInfo is generated with packed itable_ptr.
 * typeId is in upper 16 bits, itableBase in lower 16 bits.
 * 
 * This test verifies interface dispatch works with packed pointers
 * and multiple interfaces are correctly tracked.
 */
module test.interface_typeinfo;

interface IAnimal {
    int legs();
}

interface ISpeak {
    int speak();
}

class Dog : IAnimal, ISpeak {
    int legs() { return 4; }
    int speak() { return 100; }
}

class Spider : IAnimal {
    int legs() { return 8; }
}

int countLegs(IAnimal a) {
    return a.legs();
}

int makeNoise(ISpeak s) {
    return s.speak();
}

int main() {
    Dog d;
    Spider s;
    // Multiple interfaces with different typeIds
    int dogLegs = countLegs(cast(IAnimal)d);
    int spiderLegs = countLegs(cast(IAnimal)s);
    int dogSpeak = makeNoise(cast(ISpeak)d);
    return dogLegs + spiderLegs + dogSpeak;  // 4 + 8 + 100 = 112
}
