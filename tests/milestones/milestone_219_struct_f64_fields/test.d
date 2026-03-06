// Milestone 219: Struct fields with f64 (double) type
//
// Tests that struct member assignment and read use type-appropriate
// WASM instructions (f64.store/f64.load) instead of i32.store/i32.load.
// Previously, all struct field access used i32.store which truncated
// doubles to their lower 32 bits (zero for most values).

struct Vec2 {
    double x;
    double y;
}

int main() {
    Vec2 v;
    v.x = 3.0;
    v.y = 4.0;

    // Verify fields retained their values (not truncated to zero)
    double sum = v.x + v.y;

    // 3.0 + 4.0 = 7.0 → cast to int = 7
    return cast(int)sum;
}
