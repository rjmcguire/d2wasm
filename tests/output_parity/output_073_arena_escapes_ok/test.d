void inc(ref int x) {
    x = x + 1;
}

int checkRef(ref int y, int z) {
    // isRef should be true for y, false for z
    if (__traits(isRef, y) && !__traits(isRef, z))
        return 1;
    return 0;
}

int main() {
    int a = 41;
    inc(a);
    int check = checkRef(a, 0);
    return a + check;
}
