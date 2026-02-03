struct Point {
    int x;
    int get() { return this.x; }
}

int main() {
    Point p = Point(7);
    return p.get();
}
