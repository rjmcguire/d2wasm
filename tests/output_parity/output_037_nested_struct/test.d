struct Inner {
    int value;
}

struct Outer {
    Inner inner;
    int other;
}

int main() {
    Inner i = Inner(10);
    Outer o = Outer(i, 32);
    return o.inner.value + o.other;
}
