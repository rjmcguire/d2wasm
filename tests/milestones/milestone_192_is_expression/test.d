struct Point { int x; int y; }

int main() {
    int result = 0;

    // Category check: is(T == struct)
    if (is(Point == struct)) result += 10;
    if (is(int == struct)) result += 100;  // should NOT add

    // Exact type match: is(T == T)
    if (is(int == int)) result += 32;
    if (is(int == long)) result += 100;  // should NOT add

    return result;  // 42
}
