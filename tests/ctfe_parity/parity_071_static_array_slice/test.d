int test() {
    int[5] arr;
    arr[0] = 10;
    arr[1] = 20;
    arr[2] = 30;
    arr[3] = 40;
    arr[4] = 50;
    int[] sub = arr[1..4];
    return sub[0] + sub[1] + sub[2];
}

enum RESULT = test();
int main() { return RESULT; }
