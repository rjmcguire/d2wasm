struct Vec3 {
    int x;
    int y;
    int z;
}

int dot(Vec3 a, Vec3 b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

int lengthSquared(Vec3 v) {
    return dot(v, v);
}

int main() {
    Vec3 v = Vec3(3, 4, 0);
    return lengthSquared(v);  // 25
}
