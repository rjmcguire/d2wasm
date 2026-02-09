// BUG: Native backend clobbers first argument when computing second
int double_(int x) { return x * 2; }
int add(int a, int b) { return a + b; }

int test() {
    return add(double_(10), double_(11));  // Should be 42, native gets 22
}

enum RESULT = test();

int main() { return RESULT; }
