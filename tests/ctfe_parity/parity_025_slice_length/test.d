int test() {
    int[] arr = [10, 20, 30];
    return cast(int)arr.length;  // 3
}

enum RESULT = test();
int main() { return RESULT; }
