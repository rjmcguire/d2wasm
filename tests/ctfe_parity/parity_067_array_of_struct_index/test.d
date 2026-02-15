struct Point {
    int x;
    int y;
}

int test() {
    Point[2] points;
    points[0] = Point(10, 20);
    points[1] = Point(30, 40);
    int a = points[0].x;        // 10
    int b = points[1].y;        // 40
    return a + b;               // 50
}

enum RESULT = test();
int main() { return RESULT; }
