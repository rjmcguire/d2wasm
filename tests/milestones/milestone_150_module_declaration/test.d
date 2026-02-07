/**
 * Milestone 150: Module Declaration Parsing
 * 
 * Tests that module declarations are properly parsed and don't break compilation.
 * The module path should be: ["animals", "mammals", "dog"]
 */
module animals.mammals.dog;

// Simple function to verify compilation works with module declaration
int getValue() {
    return 150;  // Milestone number
}

// Test with CTFE
enum result = getValue();
static assert(result == 150, "Module declaration should not affect CTFE");
