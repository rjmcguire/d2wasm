struct Point { int x; int y; }

int test() {
    int result = 0;

    // Category check: is(T == struct)
    if (is(Point == struct)) result = result + 10;
    if (is(int == struct)) result = result + 100;  // should NOT add

    // Exact type match: is(T == T)
    if (is(int == int)) result = result + 32;
    if (is(int == long)) result = result + 100;  // should NOT add

    return result;  // 42
}

enum RESULT = test();
int main() { return RESULT; }
