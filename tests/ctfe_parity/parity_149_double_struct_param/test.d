// Double struct as function parameter
struct CGSize {
    double width;
    double height;
}

// Receive struct-with-doubles by value
int checkSize(CGSize size) {
    int w = cast(int) size.width;
    int h = cast(int) size.height;
    if (w != 100) return 1;
    if (h != 200) return 2;
    return 0;
}

int main() {
    CGSize s;
    s.width = 100.0;
    s.height = 200.0;

    int r = checkSize(s);
    if (r != 0) return 10 + r;

    return 42;
}
