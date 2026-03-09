int main() {
    int[5] a;
    float[8] b;
    int[4] c;

    // .length is a compile-time constant (element count, not byte size)
    int r1 = cast(int)a.length;  // 5
    int r2 = cast(int)b.length;  // 8
    int r3 = cast(int)c.length;  // 4

    return r1 + r2 + r3;  // 17
}
