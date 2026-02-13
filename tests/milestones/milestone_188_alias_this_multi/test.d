// Test multiple alias this declarations

struct Point {
    int x;
    int y;
}

struct Named {
    int id;
}

struct Entity {
    Point pos;
    Named info;
    int hp;
    alias pos this;
    alias info this;
}

int main() {
    Entity e = Entity(Point(10, 20), Named(5), 100);
    return e.x + e.y + e.id + e.hp;  // 10 + 20 + 5 + 100 = 135
}
