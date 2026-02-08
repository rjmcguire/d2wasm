/**
 * Milestone 162: Derived Class Layout
 * 
 * Tests that derived classes inherit base class fields:
 * - Base fields come first (after vtable_ptr)
 * - Derived fields come after base fields
 * - Both base and derived fields are accessible
 */
module test.derived_layout;

class Animal {
    int age;
    int weight;
}

class Dog : Animal {
    int barkCount;
    
    int getTotalInfo() {
        // Access inherited fields + own field
        return age + weight + barkCount;
    }
}

int testDerivedLayout() {
    Dog d;
    d.age = 5;
    d.weight = 20;
    d.barkCount = 3;
    return d.getTotalInfo();  // 5 + 20 + 3 = 28
}

int main() {
    return testDerivedLayout();  // 28
}
