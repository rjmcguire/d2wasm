double add_doubles(double a, double b) {
    return a + b;
}

double negate(double x) {
    return -x;
}

double mul3(double a, double b, double c) {
    return a * b * c;
}

int main() {
    double r1 = add_doubles(3.5, 4.25);   // 7.75
    double r2 = negate(2.5);               // -2.5
    double r3 = mul3(2.0, 3.0, 4.0);      // 24.0
    double r4 = add_doubles(negate(1.0), 10.0); // 9.0
    return cast(int)(r1 + r2 + r3 + r4);  // 38
}
