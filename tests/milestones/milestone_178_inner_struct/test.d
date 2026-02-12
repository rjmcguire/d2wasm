/**
 * Milestone 178: Inner Struct Declarations
 *
 * Tests that structs can be declared inside function bodies,
 * with methods and destructors working correctly.
 */

int test() {
    struct Counter {
        int value;

        int get() {
            return value;
        }

        void increment() {
            value = value + 1;
        }

        ~this() {
            value = 0;
        }
    }

    Counter c;
    c.value = 10;
    c.increment();
    if (c.get() != 11) return 1;

    return 0;
}
