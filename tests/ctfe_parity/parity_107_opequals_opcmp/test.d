struct Point {
    int x;

    bool opEquals(Point rhs) {
        return x == rhs.x;
    }

    int opCmp(Point rhs) {
        return x - rhs.x;
    }
}

int main() {
    Point a = Point(3);
    Point b = Point(5);
    int r = 0;
    if (a == a) r += 1;
    if (a < b) r += 2;
    if (b > a) r += 4;
    return r;
}
