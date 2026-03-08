int main() {
    float a = 10.5;
    float b = 3.25;
    float sum = a + b;       // f32_add -> 13.75
    float diff = a - b;      // f32_sub -> 7.25
    float prod = a * b;      // f32_mul -> 34.125
    float quot = a / b;      // f32_div -> 3.230769...
    // Sum all results, cast to int via i32_trunc_f32_s
    return cast(int)(sum + diff + prod + quot); // 58
}
