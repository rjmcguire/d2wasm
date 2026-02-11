// D static arrays are value types — modifications inside a function
// should NOT affect the caller's copy

int sumAndModify(int[3] arr) {
    int sum = arr[0] + arr[1] + arr[2];
    arr[0] = 999;  // modify local copy
    return sum;
}

int test() {
    int[3] arr = [10, 20, 30];
    int s = sumAndModify(arr);  // 60
    // arr[0] should still be 10 (value semantics)
    return s + arr[0];  // 60 + 10 = 70
}

enum RESULT = test();
int main() { return RESULT; }
