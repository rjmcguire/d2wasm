// Backend parity test - exercises CTFE features supported by BOTH backends
// Tests: arithmetic, comparison, control flow, recursion, function calls

int fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

int isEven(int n) {
    if (n == 0) return 1;
    return isOdd(n - 1);
}

int isOdd(int n) {
    if (n == 0) return 0;
    return isEven(n - 1);
}

int compute(int a, int b) {
    int result = 0;
    int i = 0;
    while (i < a) {
        result = result + b;
        i = i + 1;
    }
    return result;
}

int add(int x, int y) {
    return x + y;
}

// CTFE evaluations - must produce same results in both backends
enum fibResult = fib(10);           // 55
enum evenCheck = isEven(10);        // 1
enum oddCheck = isOdd(7);           // 1
enum loopResult = compute(5, 9);    // 45
enum addResult = add(20, 20);       // 40

int main() {
    // Verify CTFE results: 55 + 1 + 1 + 45 + 40 = 142
    return fibResult + evenCheck + oddCheck + loopResult + addResult;
}
