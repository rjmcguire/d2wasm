int test() {
    struct Counter {
        int value;

        int get() {
            return value;
        }

        void increment() {
            value = value + 1;
        }
    }

    Counter c;
    c.value = 10;
    c.increment();
    if (c.get() != 11) return 1;

    return 0;
}

enum RESULT = test();
int main() { return RESULT; }
