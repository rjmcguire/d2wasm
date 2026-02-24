struct Vec {
    int x;
    int y;

    Vec opUnary(string op)() {
        return Vec(-x, -y);
    }
}

int main() {
    Vec a = Vec(3, 7);
    Vec b = -a;
    return -(b.x + b.y);
}
