// Test compiler intrinsics — raw opcodes, no function call

int main() {
    int a = __intrinsic_shl(1, 4);   // 1 << 4 = 16
    int b = __intrinsic_shr_s(a, 2); // 16 >> 2 = 4
    return a + b;                     // 16 + 4 = 20
}
