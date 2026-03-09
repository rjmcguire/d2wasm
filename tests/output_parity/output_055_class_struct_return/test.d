struct Point {
    int x;
    int y;
}

class Shape {
    int id;

    Point origin() {
        return Point(0, 0);
    }

    int area() {
        return 0;
    }
}

class Rect : Shape {
    int w;
    int h;

    Point origin() {
        return Point(w, h);
    }

    int area() {
        return w * h;
    }
}

int getOriginSum(Shape s) {
    Point p = s.origin();
    return p.x + p.y;
}

int main() {
    Rect r;
    r.w = 3;
    r.h = 7;

    int a = r.area();           // 21
    int o = getOriginSum(r);    // 3+7 = 10

    return a + o;  // 31
}
