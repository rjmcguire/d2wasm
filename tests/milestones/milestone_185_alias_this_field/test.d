// Test alias this member field forwarding
struct Inner {
    int x;
    int y;
}

struct Outer {
    Inner inner;
    int z;
    alias inner this;
}

int main() {
    Outer o = Outer(Inner(10, 20), 5);
    return o.x + o.y + o.z;  // 10 + 20 + 5 = 35
}
