// Test CTFE function returning a dynamic array (int[])
// Previously this failed because evaluateCallExpressionString had no
// path for dynamic array (non-string) returns.

int[] make_ints() {
    int[] arr;
    arr ~= 10;
    arr ~= 20;
    arr ~= 30;
    return arr;
}

// Core test: enum of dynamic array type
enum INTS = make_ints();

// Verify by summing the extracted elements in another CTFE function
int sum_of_ints() {
    int[] arr = INTS;
    return arr[0] + arr[1] + arr[2];
}
enum SUM = sum_of_ints();

// Return the sum so the test runner can verify
int main() { return SUM; }
