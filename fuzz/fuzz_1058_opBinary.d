// EXPECTED: 8
struct Vec {
    int x;
    int y;

    Vec opBinary(string op)(Vec rhs) if (op == "+") {
        return Vec(x + rhs.x, y + rhs.y);
    }
}

int main() {
    auto a = Vec(1, 2);
    auto b = Vec(3, 4);
    auto c = a + b;
    __writeln(c.x + c.y - 2);
    return 0;
}
