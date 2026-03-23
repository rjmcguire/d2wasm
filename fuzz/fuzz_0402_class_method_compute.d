// STATUS: wontfix — new requires @gc annotation
// EXPECTED: 100
class Sq {
    int side;
    this(int s) { side = s; }
    int area() { return side * side; }
}

int main() {
    auto s = new Sq(10);
    __writeln(s.area());
    return 0;
}
