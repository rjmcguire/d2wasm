T add(T)(T a, T b) if (__traits(isArithmetic, T)) {
    return a + b;
}

int main() {
    return add(17, 25);  // 42
}
