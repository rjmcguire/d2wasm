/**
 * Milestone 156: Class Local Variable Codegen
 * 
 * Tests stack-allocated class instances with field access.
 * Classes are laid out like structs but with vtable_ptr at offset 0.
 */
module test.class_locals;

class Dog {
    int age;
    int weight;
}

int testClassFields() {
    Dog d;              // Zero-initialized (including vtable_ptr)
    d.age = 3;
    d.weight = 25;
    return d.age + d.weight;  // 28
}

int testMultipleInstances() {
    Dog a;
    Dog b;
    a.age = 10;
    b.age = 20;
    a.weight = 5;
    b.weight = 15;
    return a.age + b.age + a.weight + b.weight;  // 50
}

int getValue() {
    int x = testClassFields();        // 28
    int y = testMultipleInstances();  // 50
    return x + y;                      // 78
}

enum result = getValue();
static assert(result == 78);
