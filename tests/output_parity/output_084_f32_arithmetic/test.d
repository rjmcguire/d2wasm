// Output Parity Test: float (f32) arithmetic operations
// Verifies add, sub, mul, div, negation, and comparisons on f32

int main() {
    float a = 3.0;
    float b = 1.5;

    // Addition
    float sum = a + b;
    if (sum != 4.5)
        return 1;

    // Subtraction
    float diff = a - b;
    if (diff != 1.5)
        return 2;

    // Multiplication
    float prod = a * b;
    if (prod != 4.5)
        return 3;

    // Division
    float quot = a / b;
    if (quot != 2.0)
        return 4;

    // Negation
    float neg = -a;
    if (neg != -3.0)
        return 5;

    // Comparison chain
    if (a <= b)
        return 6;
    if (b >= a)
        return 7;

    // Mixed f32 expression: (a * b) + (a - b)
    float result = (a * b) + (a - b);
    // 4.5 + 1.5 = 6.0
    if (result != 6.0)
        return 8;

    return 42;
}
