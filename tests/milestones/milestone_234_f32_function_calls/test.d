float add_floats(float a, float b) {
    return a + b;
}

float negate_f(float x) {
    return -x;
}

float mul3(float a, float b, float c) {
    return a * b * c;
}

int main() {
    float r1 = add_floats(3.5, 4.25);          // 7.75
    float r2 = negate_f(2.5);                   // -2.5
    float r3 = mul3(2.0, 3.0, 4.0);            // 24.0
    float r4 = add_floats(negate_f(1.0), 10.0); // 9.0
    return cast(int)(r1 + r2 + r3 + r4);        // 38
}
