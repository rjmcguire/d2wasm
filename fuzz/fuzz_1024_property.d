// EXPECTED: 10
struct Circle {
    int radius;

    @property int diameter() {
        return radius * 2;
    }
}

int main() {
    auto c = Circle(5);
    __writeln(c.diameter);
    return 0;
}
