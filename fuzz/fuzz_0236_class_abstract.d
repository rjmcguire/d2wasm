// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 25
abstract class Shape {
    abstract int area();
}

class Square : Shape {
    int side;
    this(int s) { side = s; }
    override int area() { return side * side; }
}

int main() {
    auto s = new Square(5);
    __writeln(s.area());
    return 0;
}
