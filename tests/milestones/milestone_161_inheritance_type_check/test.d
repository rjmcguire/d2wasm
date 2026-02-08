/**
 * Milestone 161: Inheritance Type Checking
 * 
 * Tests that:
 * 1. Base class is correctly resolved to its ClassDecl
 * 2. Override signatures are validated (same signature)
 * 3. Type checking passes for valid inheritance
 */
module test.inheritance_type_check;

class Animal {
    int age;
    
    int speak() {
        return 1;
    }
    
    int getAge() {
        return 5;
    }
}

class Dog : Animal {
    int barkCount;
    
    // Override with matching signature - should compile
    int speak() {
        return 42;
    }
    
    int bark() {
        return 10;
    }
}

// Test that Dog compiles correctly with override
int testDogOverride() {
    Dog d;
    return d.speak();  // 42 (Dog's override)
}

int testDogOwnMethod() {
    Dog d;
    return d.bark();  // 10
}

int main() {
    return testDogOverride() + testDogOwnMethod();  // 42 + 10 = 52
}
