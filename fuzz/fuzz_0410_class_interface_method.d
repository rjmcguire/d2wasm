// EXPECTED: 100
interface Area {
    int area();
}

class Sq : Area {
    int s;
    this(int s) { this.s = s; }
    int area() { return s * s; }
}

int main() {
    auto sq = new Sq(10);
    __writeln(sq.area());
    return 0;
}
