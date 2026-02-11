struct Point {
    int x;
    int y;
}

int manhattan(Point a, Point b) {
    int dx = a.x - b.x;
    int dy = a.y - b.y;
    if (dx < 0) { dx = 0 - dx; }
    if (dy < 0) { dy = 0 - dy; }
    return dx + dy;
}

int test() {
    Point origin = Point(0, 0);
    Point p1 = Point(3, 4);
    Point p2 = Point(-1, 2);

    int d1 = manhattan(origin, p1);  // |3| + |4| = 7
    int d2 = manhattan(origin, p2);  // |1| + |2| = 3
    int d3 = manhattan(p1, p2);      // |4| + |2| = 6
    return d1 + d2 + d3;            // 7 + 3 + 6 = 16
}

enum RESULT = test();
int main() { return RESULT; }
