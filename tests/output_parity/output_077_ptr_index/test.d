void fill(ubyte* p, int n) {
    int i = 0;
    while (i < n) {
        p[i] = cast(ubyte)(10 + i);
        i = i + 1;
    }
}

int main() {
    ubyte[8] buf;
    fill(buf.ptr, 4);
    return cast(int) buf[0];
}
