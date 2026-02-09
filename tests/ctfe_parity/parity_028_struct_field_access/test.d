struct Point {
    int x;
    int y;
    int z;
}

int test() {
    Point p = Point(10, 20, 30);
    return p.x + p.y + p.z;  // 60
}

enum RESULT = test();
int main() { return RESULT; }
