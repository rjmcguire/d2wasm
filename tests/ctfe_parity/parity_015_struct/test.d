struct Point {
    int x;
    int y;
}

int sumPoint(Point p) {
    return p.x + p.y;
}

int test() {
    Point p = Point(10, 32);
    return sumPoint(p);
}

enum RESULT = test();

int main() { return RESULT; }
