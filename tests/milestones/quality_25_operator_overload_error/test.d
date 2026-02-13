struct Vec {
    int x;
    int y;
}

int main() {
    Vec a = Vec(1, 2);
    Vec b = Vec(3, 4);
    Vec c = a + b;
    return c.x;
}
