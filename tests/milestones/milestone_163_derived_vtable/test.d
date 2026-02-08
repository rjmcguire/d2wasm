/**
 * Milestone 163: Derived Vtable
 * 
 * Tests that derived classes:
 * - Inherit base class virtual methods
 * - Can override methods (replace slot in vtable)
 * - Can add new methods (append to vtable)
 */
module test.derived_vtable;

class Animal {
    int age;
    
    int speak() {
        return 1;  // Base implementation
    }
    
    int eat() {
        return 10;  // Base implementation
    }
}

class Dog : Animal {
    int barkCount;
    
    // Override speak
    int speak() {
        return 42;  // Dog's implementation
    }
    
    // New method
    int fetch() {
        return 100;
    }
}

int testBaseMethod() {
    Animal a;
    return a.speak();  // 1
}

int testOverride() {
    Dog d;
    return d.speak();  // 42 (override)
}

int testInheritedMethod() {
    Dog d;
    return d.eat();  // 10 (inherited from Animal)
}

int testNewMethod() {
    Dog d;
    return d.fetch();  // 100 (new method)
}

int main() {
    return testBaseMethod() + testOverride() + testInheritedMethod() + testNewMethod();
    // 1 + 42 + 10 + 100 = 153
}
