struct CGSize { double width; double height; }

struct BigBuffer {
    int[4096] data;
    int len;
}

int dummy(int x) { return x; }

int main() {
    BigBuffer buf;
    buf.len = 0;

    int winW = 1024;
    int winH = 768;

    // Function calls between winW declaration and drawSize use
    int r1 = dummy(1);
    int r2 = dummy(2);
    int r3 = dummy(3);

    CGSize drawSize;
    drawSize.width = cast(double) winW;
    drawSize.height = cast(double) winH;

    if (drawSize.width < 1023.0) return 1;
    if (drawSize.width > 1025.0) return 2;
    if (drawSize.height < 767.0) return 3;
    if (drawSize.height > 769.0) return 4;

    return 42;
}
