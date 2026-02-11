int sumArray(int[5] arr) {
    int sum = 0;
    int i = 0;
    while (i < 5) {
        sum = sum + arr[i];
        i = i + 1;
    }
    return sum;
}

int test() {
    int[5] arr = [1, 2, 3, 4, 5];
    return sumArray(arr);  // 15
}

enum RESULT = test();
int main() { return RESULT; }
