struct Point {
    int x;
    int y;
}

int test() {
    Point a = Point(1, 2);
    Point b = Point(1, 2);
    Point c = Point(3, 4);

    int result = 0;
    if (a == b) result = result + 10;   // same: +10
    if (a != c) result = result + 20;   // different: +20
    if (a == c) result = result + 100;  // different: no add
    if (a != b) result = result + 100;  // same: no add
    return result;                       // 30
}

enum RESULT = test();
int main() { return RESULT; }
