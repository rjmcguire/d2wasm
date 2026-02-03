struct Counter {
    int value;
    int get() { return 42; }
}

int main() {
    Counter c = Counter(10);
    return c.get();
}
