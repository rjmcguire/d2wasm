int abs(int x) {
    if (x < 0) {
        return 0 - x;
    }
    return x;
}

int test() {
    // Test with large positive and negative values
    int a = 2147483647;  // INT_MAX
    int b = a - 100;     // INT_MAX - 100

    // Difference should be 100
    int diff = a - b;

    // Negative arithmetic
    int c = -2147483647;
    int d = c + 100;     // -2147483547
    int diff2 = abs(d - c);  // 100

    return diff + diff2;  // 100 + 100 = 200
}

enum RESULT = test();
int main() { return RESULT; }
