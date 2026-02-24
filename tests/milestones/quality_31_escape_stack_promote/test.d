struct Vec3 {
    int x;
    int y;
    int z;
}

// Non-escaping: read all fields
int readFields() @gc(heap) {
    Vec3* v = new Vec3(10, 20, 30);
    return v.x + v.y + v.z;  // 60
}

// Non-escaping: write then read
int writeAndRead() @gc(heap) {
    Vec3* v = new Vec3(0, 0, 0);
    v.x = 7;
    v.y = 8;
    v.z = 9;
    return v.x + v.y + v.z;  // 24
}

// Non-escaping: multiple non-escaping allocations in same function
int multipleAllocs() @gc(heap) {
    Vec3* a = new Vec3(1, 2, 3);
    Vec3* b = new Vec3(4, 5, 6);
    return a.x + b.z;  // 1 + 6 = 7
}

// Non-escaping: used in a conditional
int conditionalUse(int flag) @gc(heap) {
    Vec3* v = new Vec3(100, 200, 300);
    if (flag!=0) {
        return v.x;  // 100
    }
    return v.y;  // 200
}

int main() @gc(heap) {
    int r1 = readFields();
    int r2 = writeAndRead();
    int r3 = multipleAllocs();
    int r4 = conditionalUse(1);
    int r5 = conditionalUse(0);
    return r1 + r2 + r3 + r4 + r5;  // 60 + 24 + 7 + 100 + 200 = 391
}
