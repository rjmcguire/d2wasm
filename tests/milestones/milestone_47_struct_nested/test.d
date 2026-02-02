// Test: nested structs with flattened offset calculation
struct Inner {
    int a;
    int b;
}

struct Outer {
    Inner i;
    int c;
}

int main() {
    Outer o = Outer(Inner(1, 2), 3);
    return o.i.a + o.i.b + o.c;  // 1 + 2 + 3 = 6
}
