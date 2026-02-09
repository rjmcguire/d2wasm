int test() {
    int[] arr = [1, 2];
    arr ~= 3;
    arr ~= 4;
    return cast(int)arr.length + arr[3];  // 4 + 4 = 8
}

enum RESULT = test();
int main() { return RESULT; }
