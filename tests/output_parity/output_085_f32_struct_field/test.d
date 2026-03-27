// Output Parity Test: float (f32) struct fields
// Verifies load/store of f32 fields, including mixed int/float structs

struct Vec2f {
    float x;
    float y;
}

struct Mixed {
    int id;
    float value;
    int count;
}

float dot(Vec2f a, Vec2f b) {
    return a.x * b.x + a.y * b.y;
}

int main() {
    // Pure float struct
    Vec2f v1 = Vec2f(3.0, 4.0);
    Vec2f v2 = Vec2f(1.0, 2.0);

    if (v1.x != 3.0) return 1;
    if (v1.y != 4.0) return 2;

    // Dot product: 3*1 + 4*2 = 11.0
    float d = dot(v1, v2);
    if (d != 11.0) return 3;

    // Mixed struct: int and float fields interleaved
    Mixed m = Mixed(7, 3.5, 10);
    if (m.id != 7) return 4;
    if (m.value != 3.5) return 5;
    if (m.count != 10) return 6;

    // Modify float field
    m.value = 5.5;
    if (m.value != 5.5) return 7;

    // Verify int fields weren't corrupted by float write
    if (m.id != 7) return 8;
    if (m.count != 10) return 9;

    return 42;
}
