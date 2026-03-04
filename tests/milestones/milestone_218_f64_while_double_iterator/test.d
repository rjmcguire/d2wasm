double abs_approx(double x) {
    if (x < 0.0) return -x;
    return x;
}

int main() {
    // Compute an approximation using double iteration
    double sum = 0.0;
    double step = 0.1;
    double x = step;
    int iterations = 0;
    while (x < 1.05) {
        sum = sum + x;
        x = x + step;
        iterations = iterations + 1;
    }
    // x goes: 0.1, 0.2, ..., 1.0 -- 10 iterations
    // sum = 0.1+0.2+...+1.0 = 5.5
    return iterations * 10 + cast(int) sum; // 100 + 5 = 105
}
