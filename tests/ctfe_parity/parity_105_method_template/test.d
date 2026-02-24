struct Wrapper {
    int value;
    int apply(T)(T x) {
        return value + x;
    }
}

int main() {
    Wrapper w = Wrapper(10);
    return w.apply(5);
}
