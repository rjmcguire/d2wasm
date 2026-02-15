// 3x3 matrix operations — inlined to avoid >4 argument limit
// Tests: heavy arithmetic, many local variables, function calls

int mat_det(int a, int b, int c, int d) {
    // Cofactor expansion helper: returns a*b - c*d
    return a * b - c * d;
}

int test() {
    // Matrix A
    int a00 = 2; int a01 = 3; int a02 = 1;
    int a10 = 1; int a11 = 4; int a12 = 2;
    int a20 = 3; int a21 = 1; int a22 = 2;

    // Matrix B
    int b00 = 1; int b01 = 2; int b02 = 3;
    int b10 = 2; int b11 = 1; int b12 = 2;
    int b20 = 3; int b21 = 2; int b22 = 1;

    // Compute trace(A*B) inline
    // c00 = A row0 . B col0 = 2*1 + 3*2 + 1*3 = 11
    int c00 = a00*b00 + a01*b10 + a02*b20;
    // c11 = A row1 . B col1 = 1*2 + 4*1 + 2*2 = 10
    int c11 = a10*b01 + a11*b11 + a12*b21;
    // c22 = A row2 . B col2 = 3*3 + 1*2 + 2*1 = 13
    int c22 = a20*b02 + a21*b12 + a22*b22;
    int trace = c00 + c11 + c22;
    // trace = 11+10+13 = 34

    // Compute det(A) using cofactor expansion along first row
    // det = a00*(a11*a22 - a12*a21) - a01*(a10*a22 - a12*a20) + a02*(a10*a21 - a11*a20)
    int m00 = mat_det(a11, a22, a12, a21);  // 4*2-2*1 = 6
    int m01 = mat_det(a10, a22, a12, a20);  // 1*2-2*3 = -4
    int m02 = mat_det(a10, a21, a11, a20);  // 1*1-4*3 = -11
    int det = a00 * m00 - a01 * m01 + a02 * m02;
    // det = 2*6 - 3*(-4) + 1*(-11) = 12+12-11 = 13

    return trace + det;
    // 34 + 13 = 47
}

enum RESULT = test();
int main() { return RESULT; }
