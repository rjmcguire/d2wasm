// Milestone 80: Mutual recursion in CTFE
// isEven and isOdd call each other

int isEven(int n) {
    if (n == 0) return 1;
    return isOdd(n - 1);
}

int isOdd(int n) {
    if (n == 0) return 0;
    return isEven(n - 1);
}

// Test both functions
enum even10 = isEven(10);  // 1 (true)
enum odd7 = isOdd(7);      // 1 (true)

int main() {
    return even10 + odd7;  // 1 + 1 = 2
}
