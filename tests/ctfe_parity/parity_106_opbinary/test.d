struct Vec {
    int x;
    int y;

    Vec opBinary(string op)(Vec rhs) {
        return Vec(x + rhs.x, y + rhs.y);
    }
}

int main() {
    Vec a = Vec(1, 2);
    Vec b = Vec(3, 4);
    Vec c = a + b;
    return c.x + c.y;
}
