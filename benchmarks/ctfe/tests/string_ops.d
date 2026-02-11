// CTFE Benchmark: String operations
// Tests: runtime/object.d functions, slice operations

int test() {
    string hello = "hello world";
    int idx = indexOf(hello, 'o');
    int idx2 = stringIndexOf(hello, "world");
    bool eq = stringEqual(hello, "hello world");
    int result = idx + idx2;
    if (eq) {
        result = result + 100;
    }
    return result;
}

enum RESULT = test();

int main() {
    return RESULT;
}
