// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 200
class Shape {
    int area() { return 0; }
}

class Rect : Shape {
    int w;
    int h;
    this(int w, int h) { this.w = w; this.h = h; }
    override int area() { return w * h; }
}

int main() {
    Shape s = new Rect(10, 20);
    __writeln(s.area());
    return 0;
}
