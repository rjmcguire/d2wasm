// Test basic function template in CTFE context

T max(T)(T a, T b) {
    if (a > b) return a;
    return b;
}

enum RESULT = max!int(3, 8);

int main() {
    return RESULT;
}
