/**
 * Milestone 165: Virtual Dispatch Through Base Type
 * 
 * Integration test for complete inheritance scenario:
 * - Base class with virtual methods
 * - Derived class overriding some methods
 * - Call through base type dispatches to correct implementation
 * - Inherited methods still work
 */
module test.virtual_through_base;

class Animal {
    int age;
    
    int speak() {
        return 1;  // Animal sound
    }
    
    int eat() {
        return 10;  // Eating behavior
    }
    
    int sleep() {
        return 100;  // Sleeping behavior
    }
}

class Dog : Animal {
    int barkCount;
    
    // Override speak
    int speak() {
        return 42;  // Dog bark
    }
    
    // Override eat
    int eat() {
        return 20;  // Dog eating
    }
    
    // Don't override sleep - use inherited
    
    // New method
    int fetch() {
        return 200;
    }
}

// Helper function that takes base type
int makeSound(Animal a) {
    return a.speak();
}

int feedAnimal(Animal a) {
    return a.eat();
}

int putToSleep(Animal a) {
    return a.sleep();
}

int main() {
    // Create Dog but call through Animal type
    Dog d;
    d.age = 5;
    d.barkCount = 3;
    
    // Virtual dispatch through functions
    int soundResult = makeSound(d);  // 42 (Dog.speak)
    int eatResult = feedAnimal(d);   // 20 (Dog.eat)
    int sleepResult = putToSleep(d); // 100 (Animal.sleep - inherited)
    
    // Direct method call on derived
    int fetchResult = d.fetch();     // 200
    
    // Field access through upcast
    Animal a = d;
    int ageResult = a.age;           // 5
    
    return soundResult + eatResult + sleepResult + fetchResult + ageResult;
    // 42 + 20 + 100 + 200 + 5 = 367
}
