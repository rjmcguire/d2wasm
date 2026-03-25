// Simpler large stack struct test
struct Buffer {
    ubyte[256] data;
    int len;
}

int main() {
    Buffer buf;
    buf.len = 0;

    // Write a byte
    buf.data[0] = 65;
    buf.len = 1;

    if (buf.len != 1) return 1;
    if (cast(int) buf.data[0] != 65) return 2;

    return 42;
}
