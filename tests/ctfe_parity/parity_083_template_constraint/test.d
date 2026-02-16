T add(T)(T a, T b) if (__traits(isArithmetic, T)) {
    return a + b;
}

int test() {
    return add(17, 25);
}

enum RESULT = test();
int main() { return RESULT; }
