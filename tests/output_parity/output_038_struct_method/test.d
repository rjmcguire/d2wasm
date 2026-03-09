struct Counter {
    int value;

    int get() {
        return value;
    }

    int addAndGet(int n) {
        value = value + n;
        return value;
    }
}

int main() {
    Counter c = Counter(10);
    int a = c.get();          // 10
    int b = c.addAndGet(5);   // 15
    int d = c.addAndGet(20);  // 35
    return a + b + d;         // 60
}
