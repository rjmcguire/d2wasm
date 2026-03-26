// Bug: structs with double fields placed after int variables had misaligned
// stack offsets.  ARM64 STR/LDR for d-registers use scaled immediates
// (offset/8), so a non-8-byte-aligned offset silently stores to the wrong
// location (offset truncated to next lower multiple of 8).

struct CGSize { double width; double height; }

int main() {
    // Two ints before the struct force a non-8-byte-aligned nextLocalOffset
    int winW = 1024;
    int winH = 768;

    CGSize drawSize;
    drawSize.width = cast(double) winW;
    drawSize.height = cast(double) winH;

    if (drawSize.width < 1023.0) return 1;
    if (drawSize.width > 1025.0) return 2;
    if (drawSize.height < 767.0) return 3;
    if (drawSize.height > 769.0) return 4;

    return 42;
}
