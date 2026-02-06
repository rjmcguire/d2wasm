// Milestone 131: Shadowing detection
// This should produce a compile error - shadowing is not allowed

int main() {
    int x = 10;
    {
        int x = 20;  // ERROR: shadows outer 'x'
    }
    return x;
}
