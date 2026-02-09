struct Inner {
    int value;
}

struct Outer {
    Inner inner;
    int other;
}

int test() {
    Inner i = Inner(10);
    Outer o = Outer(i, 32);
    return o.inner.value + o.other;  // 42
}

enum RESULT = test();
int main() { return RESULT; }
