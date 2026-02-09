int test() {
    int[] arr = [1, 2, 3, 4, 5];
    return arr[0] + arr[4];  // 1 + 5 = 6
}

enum RESULT = test();
int main() { return RESULT; }
