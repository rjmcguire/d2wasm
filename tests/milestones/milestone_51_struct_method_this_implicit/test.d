struct Point {
    int x;
    int get() { return x; }
}

int main() {
    Point p = Point(99);
    return p.get();
}
