struct Point {
    int x;
    int y;

    int sum() {
        return x + y;
    }
}

int helper() {
    return 10;
}

int main() {
    Point p;
    p.x = 20;
    p.y = 12;
    return p.sum() + helper() - p.x + helper();
}
