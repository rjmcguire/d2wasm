/**
 * Milestone 179: Scalar Global Variables
 *
 * Tests module-level scalar variables that can be read and
 * modified by multiple functions, with mutations persisting.
 */

int counter = 0;
int startValue = 42;

void increment() {
    counter = counter + 1;
}

int getCounter() {
    return counter;
}

int test() {
    // Test initial values
    if (startValue != 42) return 1;
    if (counter != 0) return 2;

    // Test mutation from function
    increment();
    increment();
    increment();
    if (getCounter() != 3) return 3;

    // Test direct read/write
    counter = 100;
    if (getCounter() != 100) return 4;

    // Test compound assignment
    counter += 5;
    if (counter != 105) return 5;

    return 0;
}
