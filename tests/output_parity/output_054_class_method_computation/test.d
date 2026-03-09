class Vec2 {
    int x;
    int y;

    int dot(int ox, int oy) {
        return x * ox + y * oy;
    }

    int lengthSquared() {
        return x * x + y * y;
    }

    int manhattanDist() {
        int ax = x;
        int ay = y;
        if (ax < 0) ax = 0 - ax;
        if (ay < 0) ay = 0 - ay;
        return ax + ay;
    }
}

int compute(Vec2 v) {
    int d = v.dot(2, 3);
    int ls = v.lengthSquared();
    int md = v.manhattanDist();
    return d + ls + md;
}

int main() {
    Vec2 a;
    a.x = 3;
    a.y = 4;
    int r1 = compute(a);  // 18+25+7 = 50

    Vec2 b;
    b.x = 1;
    b.y = 2;
    int r2 = compute(b);  // 8+5+3 = 16

    return r1 + r2;  // 66
}
