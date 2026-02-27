module shapes;

enum MAX_SIDES = 100;

struct Rect {
    int w;
    int h;

    int area() {
        return w * h;
    }
}

int perimeterRect(Rect r) {
    return 2 * (r.w + r.h);
}
