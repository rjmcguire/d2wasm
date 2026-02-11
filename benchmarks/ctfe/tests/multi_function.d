// CTFE Benchmark: Multiple function dependencies
// Tests: dependency analysis, cache effectiveness

int add(int a, int b) {
    return a + b;
}

int multiply(int a, int b) {
    int result = 0;
    int i = 0;
    while (i < b) {
        result = add(result, a);
        i = i + 1;
    }
    return result;
}

int factorial(int n) {
    if (n <= 1) return 1;
    return multiply(n, factorial(n - 1));
}

int sumFactorials(int n) {
    int total = 0;
    int i = 1;
    while (i <= n) {
        total = add(total, factorial(i));
        i = i + 1;
    }
    return total;
}

enum RESULT = sumFactorials(8);

int main() {
    return RESULT;
}
