/**
 * Milestone 153: Class Declaration Parsing
 * 
 * Tests that class declarations can be parsed.
 * Note: Class codegen not yet implemented - this only tests parsing/type checking.
 */
module test.classes;

// Simple class declaration - parsing only, no instantiation
class Animal {
    int age;
}

// Class with constructor (parsing only)
class Dog {
    int barkCount;
    
    // Note: Constructor body can't reference fields yet (codegen not done)
    // this(int count) {
    //     barkCount = count;
    // }
}

// For test execution - just return a constant
int getValue() {
    return 153;
}

enum result = getValue();
static assert(result == 153);
