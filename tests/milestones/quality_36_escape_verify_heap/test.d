struct Point {
    int x;
    int y;
}

Point* escaping(int x, int y) @gc(heap) {
    Point* p = new Point(x, y);
    return p;
}

int main() @gc(heap) {
    Point* p = escaping(1, 2);
    return p.x + p.y;
}
