int test() {
    int[4] arr = [10, 20, 30, 40];
    return arr[0] + arr[3];  // 10 + 40 = 50
}

enum RESULT = test();

int main() { return RESULT; }
