int test() {
    int[4] arr = [1, 2, 3, 4];
    arr[0] = 10;
    arr[2] = 30;
    return arr[0] + arr[1] + arr[2] + arr[3];  // 10 + 2 + 30 + 4 = 46
}

enum RESULT = test();
int main() { return RESULT; }
