// Bug: raw pointer parameters (TextBuffer* buf) were loaded with
// emitLoadLocal32 (32-bit) instead of emitLoadPtr (64-bit) because
// elementType was null for pointer params.  On ARM64 where stack
// addresses exceed 32 bits, the upper bits were lost → crash.

struct Data {
    int[4096] arr;   // 16 KB
    int value;
}

void setValueViaPtr(Data* d) {
    d.value = 99;
}

int readValueViaPtr(Data* d) {
    return d.value;
}

int main() {
    Data d;
    d.value = 0;

    setValueViaPtr(&d);
    if (d.value != 99) return 1;

    int v = readValueViaPtr(&d);
    if (v != 99) return 2;

    // Test array field access through pointer
    d.arr[0] = 10;
    d.arr[1] = 20;
    if (d.arr[0] != 10) return 3;
    if (d.arr[1] != 20) return 4;

    return 42;
}
