// Test __traits(hasMember) struct introspection inside CTFE function body

struct Point {
    int x;
    int y;

    int sum() {
        return x + y;
    }
}

int test() {
    int result = 0;
    if (__traits(hasMember, Point, "x")) result += 1;
    if (__traits(hasMember, Point, "y")) result += 2;
    if (__traits(hasMember, Point, "sum")) result += 4;
    if (!__traits(hasMember, Point, "z")) result += 8;
    return result;
}

enum RESULT = test();

int main() {
    return RESULT;
}
