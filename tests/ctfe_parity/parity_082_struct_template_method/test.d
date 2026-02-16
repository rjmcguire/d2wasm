struct Container(T) {
    T value;

    T doubled() {
        return value + value;
    }
}

int test() {
    Container!(int) c = Container!(int)(21);
    return c.doubled();
}

enum RESULT = test();
int main() { return RESULT; }
