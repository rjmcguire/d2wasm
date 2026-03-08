int main() {
    float x = 10.0;
    x += 5.5;    // f32_add, 15.5
    x -= 3.25;   // f32_sub, 12.25
    x *= 2.0;    // f32_mul, 24.5
    x /= 0.5;    // f32_div, 49.0
    return cast(int) x;
}
