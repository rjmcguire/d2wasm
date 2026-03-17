// EXPECTED: 1
// EXPECTED: 2
// EXPECTED: 3
struct Vec3 {
    int x;
    int y;
    int z;
}

int main() {
    auto v = Vec3(1, 2, 3);
    __writeln(v.x);
    __writeln(v.y);
    __writeln(v.z);
    return 0;
}
