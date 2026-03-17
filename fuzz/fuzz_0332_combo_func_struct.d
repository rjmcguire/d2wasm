// EXPECTED: 50
struct Rect { int w; int h; }

int area(Rect r) {
    return r.w * r.h;
}

int main() {
    __writeln(area(Rect(5, 10)));
    return 0;
}
