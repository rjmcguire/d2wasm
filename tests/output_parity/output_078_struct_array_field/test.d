struct Buf {
    int[4] data;
}

void setAt(Buf* b, int idx, int val) {
    b.data[idx] = val;
}

int getAt(Buf* b, int idx) {
    return b.data[idx];
}

int main() {
    Buf buf;
    setAt(&buf, 0, 10);
    if (getAt(&buf, 0) != 10) return 1;
    setAt(&buf, 1, 20);
    if (getAt(&buf, 1) != 20) return 2;
    if (getAt(&buf, 0) != 10) return 3;
    return 60;
}
