// Test intrinsics via CTFE

enum A = __intrinsic_shl(1, 4);   // 16
enum B = __intrinsic_shr_s(32, 3); // 4

int result() {
    return A + B;  // 20
}
