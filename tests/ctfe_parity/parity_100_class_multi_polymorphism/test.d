class Shape {
    int x;

    int area() {
        return 0;
    }
}

class Square : Shape {
    int side;

    int area() {
        return side * side;
    }
}

class Triangle : Shape {
    int base;
    int height;

    int area() {
        return base * height / 2;
    }
}

int getArea(Shape s) {
    return s.area();
}

int main() {
    Square sq;
    sq.side = 5;

    Triangle tri;
    tri.base = 6;
    tri.height = 4;

    int a1 = getArea(sq);   // virtual -> Square.area() = 25
    int a2 = getArea(tri);  // virtual -> Triangle.area() = 12

    return a1 + a2;  // 25 + 12 = 37
}
