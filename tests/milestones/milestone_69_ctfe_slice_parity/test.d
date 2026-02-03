// Milestone 69: CTFE parity with runtime for slice operations
// Verifies that compile-time evaluation matches runtime execution

int compute() {
    int[] arr = [1, 2, 3];
    arr ~= 4;
    arr ~= 5;
    return arr[0] + arr[2] + arr[4];  // 1 + 3 + 5 = 9
}

// CTFE: compute() is evaluated at compile time
enum ctResult = compute();

int main() {
    // Runtime: compute() is executed at runtime
    int rtResult = compute();
    
    // Return difference: 0 means CTFE matches runtime
    int diff = rtResult - ctResult;
    return diff;
}
