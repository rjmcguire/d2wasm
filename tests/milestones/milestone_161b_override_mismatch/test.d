/**
 * Milestone 161b: Override Signature Mismatch Error
 * 
 * Tests that mismatched override signatures cause compile error.
 */
module test.override_mismatch;

class Animal {
    int speak() {
        return 1;
    }
}

class Dog : Animal {
    // Override with WRONG signature (different return type)
    // Should cause compile error
    bool speak() {
        return true;
    }
}

int main() {
    return 0;
}
