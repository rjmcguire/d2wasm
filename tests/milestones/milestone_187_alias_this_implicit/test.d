// Test alias this implicit conversion

struct Wrapper {
    int value;
    alias value this;
}

int double_(int x) {
    return x + x;
}

int main() {
    Wrapper w = Wrapper(21);
    return double_(w);  // implicit conversion: double_(w.value) = 42
}
