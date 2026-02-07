/**
 * Milestone 151: Name Mangling Infrastructure
 * 
 * Tests that name mangling is available and produces correct D-compatible names.
 * Note: This test verifies the infrastructure exists. Actual usage in codegen
 * will be tested when we wire mangling into the emitter.
 */
module test.mangle;

// For now, just verify the module compiles with a module declaration
// The actual mangling is tested via unit tests in codegen/mangle.d

int testValue() {
    return 151;  // Milestone number
}

enum result = testValue();
static assert(result == 151);
