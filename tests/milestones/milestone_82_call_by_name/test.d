// Milestone 82: Call any function by name without recompiling
// Multiple entry points sharing same compiled context

int shared_helper() {
    return 100;
}

int entryA(int x) {
    return x + shared_helper();
}

int entryB(int x) {
    return x * 2 + shared_helper();
}

int entryC(int x) {
    return shared_helper() - x;
}

// Different entry functions, same helpers
// Should NOT recompile when switching entry points
enum a = entryA(5);    // 5 + 100 = 105
enum b = entryB(10);   // 20 + 100 = 120  
enum c = entryC(30);   // 100 - 30 = 70
enum d = entryA(1);    // 1 + 100 = 101 (back to entryA)

int main() {
    return a + b + c + d;  // 105 + 120 + 70 + 101 = 396
}
