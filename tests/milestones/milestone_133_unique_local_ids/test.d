// Milestone 133: Unique local IDs for variables
// Tests that type checker assigns unique IDs to all locals
// (This ensures codegen can use IDs instead of names)

int foo(int a, int b) {
    // a gets ID 0, b gets ID 1
    int c = a + b;  // c gets ID 2
    {
        int d = c * 2;  // d gets ID 3
        c = d;  // c is still ID 2
    }
    return c;
}

int main() {
    int x = 5;  // x gets ID 0 (separate function, IDs reset)
    int y = 7;  // y gets ID 1
    return foo(x, y);  // 5+7=12, 12*2=24
}
