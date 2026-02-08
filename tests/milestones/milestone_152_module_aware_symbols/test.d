/**
 * Milestone 152: Module-Aware Symbol Table
 * 
 * Tests that symbols are tagged with their module path.
 * This enables proper name mangling and future multi-module support.
 */
module test.symbols.aware;

// Function in a module - symbol should have module path ["test", "symbols", "aware"]
int getValue() {
    return 152;
}

// Struct in a module
struct Point {
    int x;
    int y;
}

// Verify compilation with module-aware symbols
enum result = getValue();
static assert(result == 152, "Module-aware symbols should work");
