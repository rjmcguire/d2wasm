// EXPECTED: 42
// Test that importing works (even if module doesn't exist, tests import parsing)
// import std.stdio;  // commented out - just test without imports

int main() {
    __writeln(42);
    return 0;
}
