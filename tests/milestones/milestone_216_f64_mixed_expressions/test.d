double square(double x) {
    return x * x;
}

int main() {
    double a = 3.0;
    double b = 4.0;
    // Pythagorean: sum of squares
    double sum_sq = square(a) + square(b); // 25.0

    // Nested arithmetic with mixed precedence
    // (a+b)*(a-b) + a*b = 7*(-1) + 12 = 5.0
    double expr = (a + b) * (a - b) + a * b;

    // Chained calls
    double chain = square(square(2.0)); // square(4.0) = 16.0

    return cast(int)(sum_sq + expr + chain); // 46
}
