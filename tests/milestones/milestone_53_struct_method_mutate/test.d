struct Counter {
    int value;
    void increment() { value = value + 1; }
    int get() { return value; }
}

int main() {
    Counter c = Counter(0);
    c.increment();
    return c.get();
}
