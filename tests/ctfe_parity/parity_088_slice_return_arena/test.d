int[] make(int val) {
    int[] result;
    result ~= val;
    result ~= val + 1;
    return result;
}

int test() {
    int[] a = make(10);
    int[] b = make(20);
    // Both must have their own data
    if (a[0] != 10) return 1;
    if (a[1] != 11) return 2;
    if (b[0] != 20) return 3;
    if (b[1] != 21) return 4;
    return 0;
}

enum RESULT = test();
int main() { return RESULT; }
