// Test struct template with methods

struct Container(T) {
    T value;

    T doubled() {
        return value + value;
    }
}

int main() {
    Container!(int) c = Container!(int)(21);
    return c.doubled();
}
