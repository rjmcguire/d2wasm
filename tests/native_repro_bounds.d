// Minimal reproducer for array index out of bounds in editor.d:666
// Tests: large struct on stack + string cast to ubyte[] + indexed read

struct BigStruct {
    ubyte[65536] data;
    int len;
    int[2000] extra;
}

int main() {
    BigStruct buf;
    buf.len = 0;

    string hello = "Hello";
    ubyte[] bytes = cast(ubyte[]) hello;
    int i = 0;
    while (i < 5) {
        buf.data[i] = bytes[i];
        i = i + 1;
    }
    buf.len = 5;
    return buf.data[0];
}
