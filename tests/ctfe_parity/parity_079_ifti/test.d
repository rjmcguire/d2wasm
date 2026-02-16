T max(T)(T a, T b) {
    if (a > b) return a;
    return b;
}

int test() {
    return max(3, 8);
}

enum RESULT = test();
int main() { return RESULT; }
