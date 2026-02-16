// Tests multi-function collaboration with shared mutable state via struct.
// (Module-level globals aren't available in CTFE, so use struct fields instead.)

struct State {
    int counter;
    int startValue;
}

State makeState() {
    State s;
    s.counter = 0;
    s.startValue = 42;
    return s;
}

int test() {
    State s = makeState();

    if (s.startValue != 42) return 1;
    if (s.counter != 0) return 2;

    // Increment counter 3 times
    s.counter = s.counter + 1;
    s.counter = s.counter + 1;
    s.counter = s.counter + 1;
    if (s.counter != 3) return 3;

    // Direct assign
    s.counter = 100;
    if (s.counter != 100) return 4;

    // Compound-style operation
    s.counter = s.counter + 5;
    if (s.counter != 105) return 5;

    return 0;
}

enum RESULT = test();
int main() { return RESULT; }
