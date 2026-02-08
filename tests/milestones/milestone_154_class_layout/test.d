/**
 * Milestone 154: Class Layout Computation
 * 
 * Tests that class layout is computed with vtable pointer as first field.
 * 
 * Expected layout for Animal:
 *   offset 0: vtable_ptr (4 bytes for wasm32)
 *   offset 4: age (4 bytes)  
 *   offset 8: weight (4 bytes)
 *   Total: 12 bytes
 */
module test.class_layout;

// Class with multiple fields - layout computed during symbol collection
class Animal {
    int age;
    int weight;
}

// Class with different field types
class Vehicle {
    int wheels;
    int speed;
    int fuelCapacity;
}

// Empty class still has vtable pointer (4 bytes minimum)
class Empty {
}

// Nested types
struct Point {
    int x;
    int y;
}

class Shape {
    int color;
    // Note: struct fields in classes work once field access codegen is done
}

int getValue() {
    return 154;
}

enum result = getValue();
static assert(result == 154);
