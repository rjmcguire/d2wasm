struct Point {
    int x;
    int y;
}

class Counter {
    int value;
    int step;

    int current() {
        return value;
    }

    int advance() {
        value = value + step;
        return value;
    }
}

int getInt() {
    return 7;
}

bool isPositive(int x) {
    return x > 0;
}

int testAutoBasic() {
    // auto with int literal
    auto x = 42;
    // auto with bool literal
    auto b = true;
    // auto with arithmetic expression
    auto y = x + 8;  // 50
    // auto with function call
    auto z = getInt();  // 7
    // auto with bool function
    auto pos = isPositive(z);  // true

    int result = x + y + z;  // 42 + 50 + 7 = 99
    if (b) result = result + 1;  // 100
    if (pos) result = result + 1;  // 101
    return result;
}

int testAutoStruct() {
    Point p;
    p.x = 10;
    p.y = 20;
    // auto with struct field access
    auto px = p.x;  // 10
    auto py = p.y;  // 20
    auto sum = px + py;  // 30
    return sum;
}

int testAutoClass() {
    Counter c;
    c.value = 5;
    c.step = 3;
    // auto with class field access
    auto v = c.value;  // 5
    // auto with class method call
    auto cur = c.current();  // 5
    auto adv = c.advance();  // 8
    return v + cur + adv;  // 5 + 5 + 8 = 18
}

int testAutoChained() {
    // auto inferred from another auto variable
    auto a = 10;
    auto b = a * 2;  // 20
    auto c = b + a;  // 30
    return c;
}

int testAll() {
    auto r1 = testAutoBasic();    // 101
    auto r2 = testAutoStruct();   // 30
    auto r3 = testAutoClass();    // 18
    auto r4 = testAutoChained();  // 30
    return r1 + r2 + r3 + r4;    // 179
}

enum result = testAll();
static assert(result == 179);

int main() { return result; }
