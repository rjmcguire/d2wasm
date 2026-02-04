// Milestone 81: CTFE caching
// Same helper function used by multiple enum declarations
// Should only be compiled once

int helper() {
    return 10;
}

int double_(int x) {
    return x * 2;
}

int compute1(int x) {
    return helper() + double_(x);
}

int compute2(int x) {
    return helper() * double_(x);
}

// Multiple CTFE calls sharing helpers
enum a = compute1(5);   // 10 + 10 = 20
enum b = compute2(3);   // 10 * 6 = 60
enum c = compute1(7);   // 10 + 14 = 24

int main() {
    return a + b + c;  // 20 + 60 + 24 = 104
}
