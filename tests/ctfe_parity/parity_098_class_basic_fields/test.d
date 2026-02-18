class Counter {
    int value;
    int step;

    int advance() {
        value = value + step;
        return value;
    }

    int current() {
        return value;
    }
}

int main() {
    Counter c;
    c.value = 10;
    c.step = 3;

    int a = c.advance();  // value=13, returns 13
    int b = c.advance();  // value=16, returns 16
    int cur = c.current(); // 16

    return a + b + cur;  // 13 + 16 + 16 = 45
}
