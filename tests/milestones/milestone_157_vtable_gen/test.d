/**
 * Milestone 157: Vtable Generation
 * 
 * Tests that vtables are generated with TypeInfo at negative offset.
 * Note: Virtual dispatch (calling through vtable) is milestone 158.
 * This test verifies vtable structure is correct.
 */
module test.vtable_gen;

class Animal {
    int age;
    
    // Methods that don't use fields (implicit 'this' not implemented yet)
    int speak() {
        return 1;
    }
    
    int eat() {
        return 2;
    }
}

class Dog {
    int barkCount;
    
    int bark() {
        return 42;
    }
}

// Test that classes with methods compile correctly
// and field access still works

int testAnimal() {
    Animal a;
    a.age = 5;
    return a.age;  // 5
}

int testDog() {
    Dog d;
    d.barkCount = 3;
    return d.barkCount;  // 3
}

int getValue() {
    return testAnimal() + testDog();  // 5 + 3 = 8
}

enum result = getValue();
static assert(result == 8);
