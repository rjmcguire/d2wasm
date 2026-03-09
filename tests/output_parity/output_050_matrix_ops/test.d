int mat_det(int a, int b, int c, int d) {
    return a * b - c * d;
}

int main() {
    // Matrix A
    int a00 = 2; int a01 = 3; int a02 = 1;
    int a10 = 1; int a11 = 4; int a12 = 2;
    int a20 = 3; int a21 = 1; int a22 = 2;

    // Matrix B
    int b00 = 1; int b01 = 2; int b02 = 3;
    int b10 = 2; int b11 = 1; int b12 = 2;
    int b20 = 3; int b21 = 2; int b22 = 1;

    // trace(A*B)
    int c00 = a00*b00 + a01*b10 + a02*b20;  // 11
    int c11 = a10*b01 + a11*b11 + a12*b21;  // 10
    int c22 = a20*b02 + a21*b12 + a22*b22;  // 13
    int trace = c00 + c11 + c22;             // 34

    // det(A) via cofactor expansion
    int m00 = mat_det(a11, a22, a12, a21);  // 6
    int m01 = mat_det(a10, a22, a12, a20);  // -4
    int m02 = mat_det(a10, a21, a11, a20);  // -11
    int det = a00 * m00 - a01 * m01 + a02 * m02;  // 13

    return trace + det;  // 47
}
