// Struct with long field initialized with large value
struct BigVal {
    long value;
}

int compute() {
    auto b = BigVal(5000000000);
    return cast(int)(b.value - 4999999990);
}

enum RESULT = compute();
int main() { return RESULT; }
