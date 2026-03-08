// f32 struct fields passed to functions — exercises f32_load/f32_store via shadow stack
struct Vec3f {
    float x;
    float y;
    float z;
}

float dot(Vec3f a, Vec3f b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

int main() {
    Vec3f a;
    a.x = 1.0;
    a.y = 2.0;
    a.z = 3.0;

    Vec3f b;
    b.x = 4.0;
    b.y = 5.0;
    b.z = 6.0;

    float d = dot(a, b);  // 1*4 + 2*5 + 3*6 = 32
    return cast(int) d;
}
