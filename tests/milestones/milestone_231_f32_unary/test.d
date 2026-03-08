int main() {
    float x = 7.5;
    float neg = -x;           // f32_neg -> -7.5
    float pos = +x;           // no-op -> 7.5
    float neglit = -3.25;     // f64_const + f64_neg -> f32_demote
    float double_neg = -(-x); // f32_neg + f32_neg -> 7.5
    return cast(int)(neg + pos + neglit + double_neg); // 4
}
