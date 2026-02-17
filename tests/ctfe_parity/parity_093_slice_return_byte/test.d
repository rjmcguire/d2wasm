ubyte[] make_bytes() {
    ubyte[] arr;
    arr ~= cast(ubyte)10;
    arr ~= cast(ubyte)20;
    arr ~= cast(ubyte)30;
    return arr;
}

int test() {
    ubyte[] arr = make_bytes();
    return arr[0] + arr[1] + arr[2];  // 60
}

enum RESULT = test();
int main() { return RESULT; }
