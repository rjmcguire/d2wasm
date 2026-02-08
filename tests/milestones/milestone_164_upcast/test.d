/**
 * Milestone 164: Upcasting
 * 
 * Tests that derived class can be assigned to base class type.
 * The pointer is the same (Dog's layout starts with Animal's fields).
 */
module test.upcast;

class Animal {
    int age;
    
    int speak() {
        return 1;
    }
}

class Dog : Animal {
    int barkCount;
    
    int speak() {
        return 42;
    }
}

int testUpcast() {
    Dog d;
    d.age = 5;
    
    // Upcast: Dog -> Animal
    Animal a = d;
    
    // Access inherited field through base type
    return a.age;  // 5
}

int testVirtualThroughBase() {
    Dog d;
    Animal a = d;
    
    // Virtual dispatch should still call Dog.speak
    return a.speak();  // 42
}

int main() {
    return testUpcast() + testVirtualThroughBase();
    // 5 + 42 = 47
}
