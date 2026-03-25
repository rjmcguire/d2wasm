// Bug: ArrayType.alignment() returned size() instead of elementType.alignment().
// For ubyte[65536], alignment was 65536 instead of 1, bloating struct layout
// and corrupting field offsets when array sizes aren't powers of 2.

struct Compact {
    ubyte[100] a;    // alignment should be 1, not 100
    int x;           // should be at offset 100, not some padded offset
    int[300] b;      // alignment should be 4, not 1200
    int y;           // should be at offset 100+4+1200 = 1304
}

int main() {
    Compact c;
    c.a[0] = 65;
    c.x = 10;
    c.b[0] = 20;
    c.b[299] = 30;
    c.y = 40;

    // Verify nothing was clobbered by layout errors
    if (cast(int) c.a[0] != 65) return 1;
    if (c.x != 10) return 2;
    if (c.b[0] != 20) return 3;
    if (c.b[299] != 30) return 4;
    if (c.y != 40) return 5;

    return 42;
}
