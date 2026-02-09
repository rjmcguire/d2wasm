// NOTE: Direct nested calls like add(f(x), g(y)) have a native register bug.
// Use intermediate variables as a workaround.

int double_(int x) { return x * 2; }
int add(int a, int b) { return a + b; }

int test() {
    int a = double_(10);  // 20
    int b = double_(11);  // 22
    return add(a, b);     // 42
}

enum RESULT = test();

int main() { return RESULT; }
