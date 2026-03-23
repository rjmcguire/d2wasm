// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 50
class Rect {
    int w;
    int h;

    this(int w, int h) {
        this.w = w;
        this.h = h;
    }

    int area() {
        return w * h;
    }
}

int main() {
    auto r = new Rect(5, 10);
    __writeln(r.area());
    return 0;
}
