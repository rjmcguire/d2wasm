// EXPECTED: 25
struct Sq {
    int side;
    int area() { return side * side; }
}

int main() {
    auto s = Sq(5);
    __writeln(s.area());
    return 0;
}
