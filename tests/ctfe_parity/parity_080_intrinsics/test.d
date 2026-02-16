int test() {
    int a = __intrinsic_shl(1, 4);    // 16
    int b = __intrinsic_shr_s(32, 3); // 4
    return a + b;                      // 20
}

enum RESULT = test();
int main() { return RESULT; }
