struct Point {
    int x;
    int y;
}

int nonEscaping() @gc(heap) {
    Point* p = new Point(3, 7);
    return p.x + p.y;
}

int main() @gc(heap) {
    return nonEscaping();
}
