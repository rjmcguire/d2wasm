// Test struct template with methods in CTFE

struct Container(T) {
    T value;

    T doubled() {
        return value + value;
    }
}

int compute() {
    Container!(int) c = Container!(int)(21);
    return c.doubled();
}

enum result = compute();

int main() {
    return result;
}
