// CTFE Benchmark: Loop-heavy computation
// Tests: loop overhead, arithmetic

int sumOfSquares(int n) {
    int total = 0;
    int i = 0;
    while (i < n) {
        total = total + i * i;
        i = i + 1;
    }
    return total;
}

enum RESULT = sumOfSquares(1000);

int main() {
    return RESULT;
}
