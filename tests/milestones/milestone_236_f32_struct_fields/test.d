struct Vec2f {
    float x;
    float y;
}

int main() {
    Vec2f v;
    v.x = 3.0;
    v.y = 4.0;

    float sum = v.x + v.y;  // f32_load + f32_load + f32_add -> 7.0

    return cast(int) sum;    // i32_trunc_f32_s -> 7
}
