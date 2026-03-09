int readByte(ubyte* p, int idx) {
    return cast(int)p[idx];
}

int main() {
    int[2] arr;
    arr[0] = 7;
    arr[1] = 0;

    // Cast int* to ubyte* — reinterpret the same memory as bytes
    ubyte* bp = cast(ubyte*)arr.ptr;

    // Read first byte of arr[0] (little-endian: least significant byte = 7)
    int r1 = readByte(bp, 0);  // 7

    return r1;
}
